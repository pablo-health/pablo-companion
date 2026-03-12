import AudioCaptureKit
import Foundation

/// Scans the recordings directory for orphaned recording files not linked to any session.
enum RecordingDirectoryScanner {
    /// Scan a directory for recording files, excluding those with IDs in `excluding`.
    static func scan(directory: URL, excluding linkedIDs: Set<UUID>) -> [LocalRecording] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey]
        ) else { return [] }

        let groups = groupFilesByRecording(files)
        return groups.compactMap { buildRecording(uuid: $0, group: $1, linkedIDs: linkedIDs) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Private

    private struct FileGroup {
        var wav: URL?
        var mic: URL?
        var system: URL?
        var date = Date.distantPast
    }

    private static func groupFilesByRecording(_ files: [URL]) -> [String: FileGroup] {
        var grouped: [String: FileGroup] = [:]
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            let baseName = stripSuffix(name)
            let uuidString = baseName.replacingOccurrences(of: "recording_", with: "")
            let modDate = creationDate(of: file)

            var group = grouped[uuidString, default: FileGroup()]
            if modDate > group.date { group.date = modDate }

            if name.hasSuffix("_mic") {
                group.mic = file
            } else if name.hasSuffix("_system") {
                group.system = file
            } else {
                group.wav = file
            }
            grouped[uuidString] = group
        }
        return grouped
    }

    private static func buildRecording(
        uuid uuidString: String,
        group: FileGroup,
        linkedIDs: Set<UUID>
    ) -> LocalRecording? {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        guard !linkedIDs.contains(uuid) else { return nil }
        guard let wav = group.wav else { return nil }
        let size = fileSize(wav)
        guard size > 100 else { return nil }
        if let mic = group.mic, fileSize(mic) == 0 { return nil }

        let isEncrypted = wav.lastPathComponent.contains(".enc")
        let duration = estimateDuration(fileSize: size, isEncrypted: isEncrypted)
        return LocalRecording(
            id: uuid,
            fileURL: wav,
            duration: duration,
            createdAt: group.date,
            isEncrypted: isEncrypted,
            checksum: "",
            channelLayout: group.system != nil ? .separatedStereo : .blended,
            micPCMFileURL: group.mic,
            systemPCMFileURL: group.system,
            isUploaded: false
        )
    }

    private static func stripSuffix(_ name: String) -> String {
        var result = name
        // Strip .enc from double-extension filenames (e.g. "recording_UUID.enc")
        if result.hasSuffix(".enc") { result = String(result.dropLast(4)) }
        if result.hasSuffix("_mic") { return String(result.dropLast(4)) }
        if result.hasSuffix("_system") { return String(result.dropLast(7)) }
        return result
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    private static func creationDate(of url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.creationDateKey])
        return values?.creationDate ?? .distantPast
    }

    private static func estimateDuration(fileSize: Int, isEncrypted: Bool) -> TimeInterval {
        let headerSize = isEncrypted ? 100 : 44
        let bytesPerSecond = 48000 * 2 * 2 // 48kHz × 16-bit × stereo
        let dataSize = max(0, fileSize - headerSize)
        return TimeInterval(dataSize) / TimeInterval(bytesPerSecond)
    }
}
