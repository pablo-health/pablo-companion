import Foundation

/// Response from `POST /api/sessions/{session_id}/upload-audio`.
/// Returned after the backend accepts audio files for server-side transcription.
public struct AudioUploadResponse: Codable, Sendable {
    public let id: String
    public let status: String
    public let queue: String?
    public let message: String?

    public init(id: String, status: String, queue: String?, message: String?) {
        self.id = id
        self.status = status
        self.queue = queue
        self.message = message
    }
}
