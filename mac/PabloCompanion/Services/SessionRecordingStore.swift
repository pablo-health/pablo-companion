import AudioCaptureKit
import Foundation
import os

/// Persists the session → recording mapping so it survives app restarts.
///
/// Stored as plain JSON at `~/Library/Application Support/PabloCompanion/SessionRecordings.json`.
/// Contains NO PHI — only session IDs (backend UUIDs), recording IDs (local UUIDs),
/// file paths, and technical metadata.
struct SessionRecordingStore {
    // MARK: - Types

    struct RecordingEntry: Codable {
        let recordingID: UUID
        let fileURL: String
        let duration: TimeInterval
        let createdAt: Date
        let isEncrypted: Bool
        let checksum: String
        let channelLayout: String
        let micPCMFilePath: String?
        let systemPCMFilePath: String?
    }

    // MARK: - Private

    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "SessionRecordingStore")

    private var storeURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        let dir = appSupport.appendingPathComponent("PabloCompanion", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("SessionRecordings.json")
    }

    // MARK: - Public API

    /// Load the full session→recording map from disk.
    func loadAll() -> [String: RecordingEntry] {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return [:] }
        do {
            let data = try Data(contentsOf: storeURL)
            return try JSONDecoder().decode([String: RecordingEntry].self, from: data)
        } catch {
            logger.warning("Failed to load session recording map: \(error.localizedDescription)")
            return [:]
        }
    }

    /// Save a single session→recording mapping, merging with existing entries.
    func save(sessionId: String, entry: RecordingEntry) {
        var map = loadAll()
        map[sessionId] = entry
        write(map)
    }

    /// Persist the full map (used for bulk operations).
    func write(_ map: [String: RecordingEntry]) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(map)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            logger.error("Failed to save session recording map: \(error.localizedDescription)")
        }
    }

    // MARK: - Convenience

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
            systemPCMFilePath: recording.systemPCMFileURL?.path
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
            isUploaded: false
        )
    }
}
