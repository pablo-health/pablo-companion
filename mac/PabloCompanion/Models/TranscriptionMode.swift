import Foundation

/// Controls whether audio is transcribed locally (Whisper on-device) or uploaded
/// to the Pablo backend for server-side transcription.
///
/// Default is `.cloud` — audio is sent to the backend. Therapists on macOS can
/// opt into `.local` via Settings if they prefer on-device processing.
enum TranscriptionMode: String, CaseIterable, Sendable {
    /// Upload audio to Pablo backend for server-side Whisper + SOAP pipeline.
    case cloud
    /// Transcribe locally on this Mac using the Whisper model.
    case local
}
