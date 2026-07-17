import AudioCaptureKit
import CompanionSessionCore
import Foundation

/// The bridge between the persisted entry and the app's UI model.
///
/// This is why the store itself could not move for so long: `LocalRecording` and
/// `ChannelLayout` come from AudioCaptureKit, which is .macOS(.v14) only, while
/// CompanionSessionCore must build on Linux for the harness. But the coupling was
/// never in the store — only in these two converters, which are pure mapping and
/// belong on the app side of the line.
extension SessionRecordingStore {
    /// Create a RecordingEntry from a LocalRecording.
    static func entry(from recording: LocalRecording) -> RecordingEntry {
        RecordingEntry(
            recordingID: recording.id,
            fileURL: recording.fileURL.path,
            duration: recording.duration,
            createdAt: recording.createdAt,
            isEncrypted: recording.isEncrypted,
            checksum: recording.checksum,
            channelLayout: recording.channelLayout.rawValue,
            micPCMFilePath: recording.micPCMFileURL?.path,
            systemPCMFilePath: recording.systemPCMFileURL?.path,
            sampleRate: recording.sampleRate
        )
    }

    /// Reconstruct a LocalRecording from a persisted entry, if files still exist on disk.
    static func localRecording(from entry: RecordingEntry) -> LocalRecording? {
        let fileURL = URL(fileURLWithPath: entry.fileURL)
        // At minimum, either the main file or a PCM sidecar must exist
        let mainExists = FileManager.default.fileExists(atPath: entry.fileURL)
        let micExists = entry.micPCMFilePath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        guard mainExists || micExists else { return nil }

        return LocalRecording(
            id: entry.recordingID,
            fileURL: fileURL,
            duration: entry.duration,
            createdAt: entry.createdAt,
            isEncrypted: entry.isEncrypted,
            checksum: entry.checksum,
            channelLayout: ChannelLayout(rawValue: entry.channelLayout) ?? .blended,
            micPCMFileURL: entry.micPCMFilePath.map { URL(fileURLWithPath: $0) },
            systemPCMFileURL: entry.systemPCMFilePath.map { URL(fileURLWithPath: $0) },
            sampleRate: entry.sampleRate ?? 48000,
            isUploaded: false
        )
    }
}
