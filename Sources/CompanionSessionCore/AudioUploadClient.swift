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
        sampleRate: Int = 48000,
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

        // The sidecars are headerless PCM: mic is mono, system audio is stereo.
        // Prepend an accurate WAV header per channel so the audio is
        // self-describing — the backend no longer has to guess the format
        // (its guess, always-stereo, corrupts the mono mic channel).
        var parts = try [MultipartFilePart(
            fieldName: "therapist_audio",
            fileName: Self.wavName(therapistAudioURL),
            mimeType: "audio/wav",
            data: Self.wavData(Data(contentsOf: therapistAudioURL), sampleRate: sampleRate, channels: 1)
        )]

        onProgress(0.3)

        if let clientAudioURL, let clientData = try? Data(contentsOf: clientAudioURL) {
            parts.append(MultipartFilePart(
                fieldName: "client_audio",
                fileName: Self.wavName(clientAudioURL),
                mimeType: "audio/wav",
                data: Self.wavData(clientData, sampleRate: sampleRate, channels: 2)
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

    /// The shared upload entry point for the app and the harness. Routes to the
    /// signed-URL direct-to-storage path (``uploadAudioViaSignedURL``), healing a
    /// `400 INVALID_STATUS` rejection once.
    ///
    /// Why signed-URL, not multipart: a full-length session is hundreds of MB.
    /// The multipart path (``uploadAudio``) sends it as one POST through the
    /// app's load balancer, whose request-size ceiling 413s the request before
    /// it reaches the app. The signed-URL path PUTs each channel straight to
    /// object storage, so only two small backend JSON calls (init + finalize)
    /// traverse the load balancer.
    ///
    /// The heal mirrors the multipart one: the backend rejects finalize while
    /// the session is still `recording`; healing PATCHes it to `recoveryStatus`
    /// (default `recording_complete`) and re-finalizes once. Because the audio
    /// is already in storage by then, the heal never re-uploads it.
    public func uploadWithSelfHeal(
        sessionId: String,
        therapistAudioURL: URL,
        clientAudioURL: URL?,
        sampleRate: Int = 48000,
        recoveryStatus: String = "recording_complete",
        onProgress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> AudioUploadResponse {
        try await uploadAudioViaSignedURL(
            sessionId: sessionId,
            therapistAudioURL: therapistAudioURL,
            clientAudioURL: clientAudioURL,
            sampleRate: sampleRate,
            recoveryStatus: recoveryStatus,
            onProgress: onProgress
        )
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

    /// Wraps headerless PCM in a WAV header; passes through anything already RIFF.
    private static func wavData(_ data: Data, sampleRate: Int, channels: Int) -> Data {
        // Already a self-describing container (WAV or ADTS AAC)? Pass through.
        if data.prefix(4) == Data("RIFF".utf8) || isADTSSync(data) { return data }
        return WAVEncoder.wrap(pcm: data, sampleRate: sampleRate, channels: channels)
    }

    /// Names the uploaded part `.wav` (the bytes now carry a real WAV header).
    private static func wavName(_ url: URL) -> String {
        url.deletingPathExtension().appendingPathExtension("wav").lastPathComponent
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

// MARK: - Signed-URL direct-to-storage upload

extension AudioUploadClient {
    /// Uploads both channels via signed URLs straight to object storage, then
    /// finalizes — the path that keeps a full-length session off the app's
    /// load balancer (see ``uploadWithSelfHeal`` for the why).
    ///
    /// Flow: `POST …/upload-audio/init` (Bearer + DPoP) mints two signed PUT
    /// recipes → each channel's WAV is `PUT` **directly to storage** (no Bearer,
    /// no DPoP — the signed URL is the auth), **streamed from disk** so the
    /// hundreds-of-MB session never enters the heap → `POST …/upload-audio/
    /// finalize` (Bearer + DPoP) verifies both blobs and starts transcription.
    ///
    /// Both channels are required: finalize 400s if either blob is missing.
    public func uploadAudioViaSignedURL(
        sessionId: String,
        therapistAudioURL: URL,
        clientAudioURL: URL?,
        sampleRate: Int = 48000,
        recoveryStatus: String = "recording_complete",
        onProgress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> AudioUploadResponse {
        // The capture graph always writes a system (client) channel next to the
        // mic; finalize verifies both blobs and 400s if one is missing, so a
        // caller with no client audio must fail up front, not opaquely at
        // finalize after two backend round-trips.
        guard let clientAudioURL else {
            throw SessionUploadError(
                statusCode: -1,
                code: nil,
                message: "Signed-URL upload requires both therapist and client audio channels"
            )
        }

        onProgress(0.05)
        let initResponse = try await initSignedUpload(sessionId: sessionId)
        onProgress(0.15)

        // Produce the exact WAV bytes the backend/transcription expects (mic =
        // mono, system = stereo) as files on disk, so the PUT streams from disk.
        let therapist = try Self.wavFileForUpload(source: therapistAudioURL, sampleRate: sampleRate, channels: 1)
        defer { if therapist.isTemp { try? FileManager.default.removeItem(at: therapist.url) } }
        let client = try Self.wavFileForUpload(source: clientAudioURL, sampleRate: sampleRate, channels: 2)
        defer { if client.isTemp { try? FileManager.default.removeItem(at: client.url) } }

        try await putChannel(initResponse.therapist.upload, fileURL: therapist.url, label: "therapist")
        onProgress(0.55)
        try await putChannel(initResponse.client.upload, fileURL: client.url, label: "client")
        onProgress(0.85)

        // Finalize checks session status; it can 400 INVALID_STATUS just as the
        // multipart path did (session still `recording`). Heal once — the blobs
        // are already in storage, so this never re-uploads the audio.
        do {
            let done = try await finalizeSignedUpload(sessionId: sessionId)
            onProgress(1.0)
            return done
        } catch let error as SessionUploadError where Self.isInvalidStatus(error) {
            #if canImport(os)
            logger.warning("Finalize returned INVALID_STATUS — attempting self-heal")
            #endif
            try await updateSessionStatus(sessionId: sessionId, status: recoveryStatus)
            let done = try await finalizeSignedUpload(sessionId: sessionId)
            #if canImport(os)
            logger.info("Audio finalize succeeded after self-heal")
            #endif
            onProgress(1.0)
            return done
        }
    }

    // MARK: - Steps

    private func initSignedUpload(sessionId: String) async throws -> AudioUploadInitResponse {
        let bearer = try await token()
        let endpoint = "\(baseURLString)/api/sessions/\(sessionId)/upload-audio/init"
        guard let url = URL(string: endpoint) else {
            throw SessionUploadError(statusCode: -1, code: nil, message: "Invalid init URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("pablo-companion-macos/1.0", forHTTPHeaderField: "X-Client-Type")
        attachBinding(&request)

        let (data, response) = try await session.data(for: request)
        try Self.throwIfError(data: data, response: response)
        return try JSONDecoder().decode(AudioUploadInitResponse.self, from: data)
    }

    /// PUTs one channel's file straight to object storage using the signed
    /// recipe. No Bearer/DPoP — the signed URL is the auth — and the request
    /// goes to the storage host directly, bypassing the app's load balancer.
    private func putChannel(_ target: UploadTarget, fileURL: URL, label: String) async throws {
        guard let url = URL(string: target.url) else {
            throw SessionUploadError(statusCode: -1, code: nil, message: "Invalid \(label) signed upload URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = target.method
        // Replay exactly the signed headers (Content-Type + the
        // x-goog-content-length-range). Adding or dropping any makes GCS reject
        // the PUT with 403 SignatureDoesNotMatch.
        for (name, value) in target.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        // Stream from disk — never load the ~hundreds-of-MB channel into memory.
        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        try Self.throwIfError(data: data, response: response)
        #if canImport(os)
        logger.info("PUT \(label, privacy: .public) channel to storage")
        #endif
    }

    private func finalizeSignedUpload(sessionId: String) async throws -> AudioUploadResponse {
        let bearer = try await token()
        let endpoint = "\(baseURLString)/api/sessions/\(sessionId)/upload-audio/finalize"
        guard let url = URL(string: endpoint) else {
            throw SessionUploadError(statusCode: -1, code: nil, message: "Invalid finalize URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("pablo-companion-macos/1.0", forHTTPHeaderField: "X-Client-Type")
        attachBinding(&request)

        let (data, response) = try await session.data(for: request)
        try Self.throwIfError(data: data, response: response)
        return try JSONDecoder().decode(AudioUploadResponse.self, from: data)
    }

    // MARK: - WAV-on-disk

    /// Prepares one channel's upload body as a file on disk so the PUT streams
    /// from disk instead of buffering the whole session in memory.
    ///
    /// - If `source` is already a self-describing container — a `RIFF` WAV or an
    ///   ADTS AAC stream — return it unchanged (PUT the source directly,
    ///   `isTemp: false`); the backend/transcription reads the format from the
    ///   bytes.
    /// - Otherwise `source` is headerless little-endian PCM (the capture's
    ///   sidecar): write a WAV header sized to the source, then copy the PCM in
    ///   1 MiB chunks. Returns the temp URL with `isTemp: true` so the caller
    ///   deletes it after the upload. Memory stays flat regardless of length.
    static func wavFileForUpload(
        source: URL,
        sampleRate: Int,
        channels: Int
    ) throws -> (url: URL, isTemp: Bool) {
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }

        let magic = try reader.read(upToCount: 4) ?? Data()
        // Self-describing containers pass through untouched: RIFF (WAV) or an
        // ADTS AAC frame sync (0xFF 0xFn with the layer bits clear).
        if magic == Data("RIFF".utf8) || isADTSSync(magic) {
            return (source, false)
        }

        let byteCount = try (FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int) ?? 0
        let header = WAVEncoder.header(dataByteCount: byteCount, sampleRate: sampleRate, channels: channels)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pablo-upload-\(UUID().uuidString).wav")
        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
            throw SessionUploadError(statusCode: -1, code: nil, message: "Could not stage WAV for upload")
        }
        let writer = try FileHandle(forWritingTo: tempURL)
        defer { try? writer.close() }

        try reader.seek(toOffset: 0)
        try writer.write(contentsOf: header)
        let chunkSize = 1 << 20 // 1 MiB — bounded memory regardless of session length
        while true {
            let chunk = try reader.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            try writer.write(contentsOf: chunk)
        }
        return (tempURL, true)
    }

    /// True if `bytes` starts with an ADTS AAC frame sync: a 12-bit syncword
    /// (0xFFF) followed by a zero layer field — byte 0 == 0xFF and
    /// (byte 1 & 0xF6) == 0xF0.
    static func isADTSSync(_ bytes: Data) -> Bool {
        bytes.count >= 2 && bytes[bytes.startIndex] == 0xFF
            && (bytes[bytes.startIndex + 1] & 0xF6) == 0xF0
    }
}
