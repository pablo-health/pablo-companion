import AudioCaptureKit
import Foundation

/// A locally stored recording with metadata for display and upload tracking.
struct LocalRecording: Identifiable, Sendable {
    let id: UUID
    let fileURL: URL
    let duration: TimeInterval
    let createdAt: Date
    let isEncrypted: Bool
    let checksum: String
    /// Channel layout of the WAV file. `.separatedStereo` means Ch1=mic, Ch2=system audio.
    let channelLayout: ChannelLayout
    var isUploaded: Bool
    /// Raw PCM sidecar file for the microphone channel (mono, Float32).
    /// Present when the session was captured with `exportRawPCM` enabled.
    let micPCMFileURL: URL?
    /// Raw PCM sidecar file for the system audio channel (stereo interleaved, Float32).
    /// Present when the session was captured with `exportRawPCM` enabled and system audio was active.
    let systemAudioPCMFileURL: URL?

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: createdAt)
    }

    var fileName: String {
        fileURL.lastPathComponent
    }
}
