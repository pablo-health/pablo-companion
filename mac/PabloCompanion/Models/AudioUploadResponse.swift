import Foundation

/// Response from `POST /api/sessions/{session_id}/upload-audio`.
/// Returned after the backend accepts audio files for server-side transcription.
struct AudioUploadResponse: Codable, Sendable {
    let id: String
    let status: String
    let queue: String?
    let message: String?
}
