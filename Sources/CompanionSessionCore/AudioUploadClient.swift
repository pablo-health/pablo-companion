import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(os)
import os
#endif

/// The real session audio-upload wire path, shared by the shipping macOS app and
/// the headless end-to-end harness so neither can drift from the other.
///
/// It owns exactly the pieces whose format a reimplementation would get subtly
/// wrong: the `multipart/form-data` body (raw PCM sidecar bytes sent under an
/// `audio/wav` mime, `therapist_audio` / `client_audio` fields), the device
/// binding attach, and the `INVALID_STATUS` → `recording_complete` self-heal.
///
/// Auth and device binding are injected so the same code runs under the app's
/// Keychain/Secure-Enclave identity and the harness's software test key:
/// - ``token`` supplies a fresh Bearer token.
/// - ``attachBinding`` stamps the `DPoP` proof + `X-Install-ID` headers (or
///   neither, when not enrolled) — identical to the app's `attachDeviceBinding`.
public struct AudioUploadClient: Sendable {
    private let baseURLString: String
    private let token: @Sendable () async throws -> String
    private let attachBinding: @Sendable (inout URLRequest) -> Void
    private let session: URLSession

    #if canImport(os)
    private let logger: Logger
    #endif

    /// - Parameters:
    ///   - baseURLString: Backend origin, e.g. `https://app.pablo.health` (no trailing slash).
    ///   - token: Supplies a fresh Bearer token per request.
    ///   - attachBinding: Stamps device-binding headers onto a request (both
    ///     `DPoP` + `X-Install-ID`, or neither). The app passes its
    ///     `attachDeviceBinding`; the harness passes the enrolled install's proof.
    ///   - session: URLSession to use (defaults to `.shared`).
    ///   - logSubsystem: os.Logger subsystem (default `health.pablo.companion`).
    public init(
        baseURLString: String,
        token: @escaping @Sendable () async throws -> String,
        attachBinding: @escaping @Sendable (inout URLRequest) -> Void,
        session: URLSession = .shared,
        logSubsystem: String = "health.pablo.companion"
    ) {
        self.baseURLString = baseURLString
        self.token = token
        self.attachBinding = attachBinding
        self.session = session
        #if canImport(os)
        self.logger = Logger(subsystem: logSubsystem, category: "AudioUploadClient")
        #endif
    }

    // MARK: - Upload

    /// Uploads therapist (mic) and optional client (system) audio to
    /// `POST /api/sessions/{id}/upload-audio` as `multipart/form-data`.
    ///
    /// The session must already be in `recording_complete`; if it isn't the
    /// backend returns `400 INVALID_STATUS` and
    /// ``uploadWithSelfHeal(sessionId:therapistAudioURL:clientAudioURL:recoveryStatus:onProgress:)``
    /// is the entry point that recovers.
    public func uploadAudio(
        sessionId: String,
        therapistAudioURL: URL,
        clientAudioURL: URL?,
        onProgress: @Sendable (Double) -> Void
    ) async throws -> AudioUploadResponse {
        let bearer = try await token()

        let endpoint = "\(baseURLString)/api/sessions/\(sessionId)/upload-audio"
        guard let url = URL(string: endpoint) else {
            throw SessionUploadError(statusCode: -1, code: nil, message: "Invalid upload URL")
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("pablo-companion-macos/1.0", forHTTPHeaderField: "X-Client-Type")
        // Hand-rolled multipart request (not routed through the JSON builder),
        // so attach the device binding explicitly.
        attachBinding(&request)

        onProgress(0.1)

        var parts = try [MultipartFilePart(
            fieldName: "therapist_audio",
            fileName: therapistAudioURL.lastPathComponent,
            mimeType: "audio/wav",
            data: Data(contentsOf: therapistAudioURL)
        )]

        onProgress(0.3)

        if let clientAudioURL, let clientData = try? Data(contentsOf: clientAudioURL) {
            parts.append(MultipartFilePart(
                fieldName: "client_audio",
                fileName: clientAudioURL.lastPathComponent,
                mimeType: "audio/wav",
                data: clientData
            ))
        }

        onProgress(0.5)

        request.httpBody = buildMultipartBody(parts: parts, boundary: boundary)

        let (data, response) = try await session.data(for: request)

        onProgress(0.9)

        try Self.throwIfError(data: data, response: response)

        let decoded = try JSONDecoder().decode(AudioUploadResponse.self, from: data)
        onProgress(1.0)
        #if canImport(os)
        logger.info("Audio uploaded for session \(sessionId, privacy: .public)")
        #endif
        return decoded
    }

    /// Uploads audio, healing a `400 INVALID_STATUS` rejection once.
    ///
    /// The backend rejects the upload while the session is still `recording`;
    /// the heal PATCHes it to `recoveryStatus` (default `recording_complete`) and
    /// retries the upload a single time. Any other error propagates unchanged.
    public func uploadWithSelfHeal(
        sessionId: String,
        therapistAudioURL: URL,
        clientAudioURL: URL?,
        recoveryStatus: String = "recording_complete",
        onProgress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> AudioUploadResponse {
        do {
            return try await uploadAudio(
                sessionId: sessionId,
                therapistAudioURL: therapistAudioURL,
                clientAudioURL: clientAudioURL,
                onProgress: onProgress
            )
        } catch let error as SessionUploadError where Self.isInvalidStatus(error) {
            #if canImport(os)
            logger.warning("Upload returned INVALID_STATUS — attempting self-heal")
            #endif
            try await updateSessionStatus(sessionId: sessionId, status: recoveryStatus)
            let response = try await uploadAudio(
                sessionId: sessionId,
                therapistAudioURL: therapistAudioURL,
                clientAudioURL: clientAudioURL,
                onProgress: onProgress
            )
            #if canImport(os)
            logger.info("Audio upload succeeded after self-heal")
            #endif
            return response
        }
    }

    /// PATCHes `POST /api/sessions/{id}/status` to `status` (raw wire value).
    public func updateSessionStatus(sessionId: String, status: String) async throws {
        let bearer = try await token()
        let endpoint = "\(baseURLString)/api/sessions/\(sessionId)/status"
        guard let url = URL(string: endpoint) else {
            throw SessionUploadError(statusCode: -1, code: nil, message: "Invalid status URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        attachBinding(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["status": status])

        let (data, response) = try await session.data(for: request)
        try Self.throwIfError(data: data, response: response)
    }

    // MARK: - Error mapping

    private static func isInvalidStatus(_ error: SessionUploadError) -> Bool {
        error.statusCode == 400 && error.code == "INVALID_STATUS"
    }

    /// Throws ``SessionUploadError`` for any non-2xx response, parsing the
    /// backend error envelope for the structured `code`.
    private static func throwIfError(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw SessionUploadError(statusCode: -1, code: nil, message: "Non-HTTP response")
        }
        guard !(200 ... 299).contains(http.statusCode) else { return }

        let rawBody = String(data: data, encoding: .utf8) ?? "Unknown error"
        let envelope = SessionUploadError.parseEnvelope(data)
        throw SessionUploadError(
            statusCode: http.statusCode,
            code: envelope?.code,
            message: envelope?.message ?? rawBody
        )
    }
}
