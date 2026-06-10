import Foundation
import PracticeClientCore

// MARK: - Audio Upload (native URLSession multipart)

extension APIClient {
    /// Uploads therapist and client audio files to the backend for server-side transcription.
    /// Uses native URLSession multipart/form-data since this endpoint is not in pablo-core.
    ///
    /// - Parameters:
    ///   - sessionId: The backend session UUID (must be in `recording_complete` status).
    ///   - therapistAudioURL: Path to the mic PCM/WAV sidecar file.
    ///   - clientAudioURL: Path to the system audio PCM/WAV sidecar file (optional).
    ///   - onProgress: Progress callback (0.0-1.0). Simulated since URLSession upload
    ///     progress requires delegate-based uploads.
    /// - Returns: `AudioUploadResponse` with the session's new status.
    func uploadAudio(
        sessionId: String,
        therapistAudioURL: URL,
        clientAudioURL: URL?,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> AudioUploadResponse {
        let token = try await requireToken()

        let endpoint = "\(baseURLString)/api/sessions/\(sessionId)/upload-audio"
        guard let url = URL(string: endpoint) else {
            throw APIError.invalidResponse
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("pablo-companion-macos/1.0", forHTTPHeaderField: "X-Client-Type")
        // This endpoint hand-rolls its request (multipart) rather than going
        // through buildRequest, so attach the device binding explicitly.
        Self.attachDeviceBinding(to: &request)

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

        let (data, response) = try await URLSession.shared.data(for: request)

        onProgress(0.9)

        // Route non-2xx through the shared error mapper so callers see a typed
        // PabloError with the backend's structured `error.code` populated.
        // Lets `uploadAudioToBackend` branch on `INVALID_STATUS` for self-heal.
        // mapHTTPErrors also performs the `URLResponse` -> `HTTPURLResponse` cast.
        try mapHTTPErrors(data: data, response: response)

        let decoded = try JSONDecoder().decode(AudioUploadResponse.self, from: data)
        onProgress(1.0)
        logger.info("Audio uploaded for session \(sessionId)")
        return decoded
    }
}
