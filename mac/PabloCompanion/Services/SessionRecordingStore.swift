import AudioCaptureKit
import CompanionSessionCore
import Foundation
import os

/// Persists the session → recording mapping so it survives app restarts.
///
/// Stored as AES-256-GCM encrypted JSON at
/// `~/Library/Application Support/PabloCompanion/SessionRecordings.enc`.
/// Although the data contains only session IDs, recording IDs, and file paths
/// (no clinical PHI), session IDs can correlate to patient records on the backend,
/// so we encrypt to match the PendingTranscriptStore security posture.
///
/// Falls back to reading the legacy unencrypted `.json` file on first access
/// and migrates it to the encrypted format.
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
        /// Actual sample rate of the PCM sidecar files (may be < 48 kHz with Bluetooth HFP).
        let sampleRate: Double?
    }

    // MARK: - Private

    /// User email for per-user encryption key scoping. Set after sign-in.
    var userEmail: String?

    /// Builds the encryptor used to seal entries at rest.
    ///
    /// A factory of the `SessionDataEncrypting` abstraction, never the concrete
    /// `RecordingEncryptor`: that type is macOS-bound via AudioCaptureKit, and
    /// naming it here would stop this store moving into the Foundation-only
    /// `CompanionSessionCore` where the harness could exercise it.
    ///
    /// Tests substitute a fake, which is what keeps them off the real Keychain.
    /// Returning nil means "no key" — callers must refuse to write rather than
    /// write something readable.
    let makeEncryptor: SessionEncryptorFactory

    /// - Parameter makeEncryptor: has no default on purpose. A default of
    ///   `{ RecordingEncryptor(userEmail: $0) }` would name a type that conforms
    ///   to AudioCaptureKit's `CaptureEncryptor` — macOS-only — and re-couple
    ///   this store to it, which is precisely what the abstraction exists to
    ///   avoid. The app supplies the concrete encryptor at construction.
    init(makeEncryptor: @escaping SessionEncryptorFactory) {
        self.makeEncryptor = makeEncryptor
    }

    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "SessionRecordingStore")

    private var storeDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        let dir = appSupport.appendingPathComponent("PabloCompanion", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var encryptedStoreURL: URL {
        storeDirectory.appendingPathComponent("SessionRecordings.enc")
    }

    /// Legacy plaintext store path — used for migration only.
    private var legacyStoreURL: URL {
        storeDirectory.appendingPathComponent("SessionRecordings.json")
    }

    // MARK: - Public API

    /// Load the full session→recording map from disk (decrypting on read).
    /// On first call after upgrade, migrates the legacy plaintext JSON to encrypted format.
    func loadAll() -> [String: RecordingEntry] {
        // Try encrypted store first
        if FileManager.default.fileExists(atPath: encryptedStoreURL.path) {
            return loadEncrypted() ?? [:]
        }

        // Migrate legacy plaintext store if it exists
        if FileManager.default.fileExists(atPath: legacyStoreURL.path) {
            let migrated = loadLegacy()
            if !migrated.isEmpty {
                write(migrated)
                // Remove legacy file after successful migration
                try? FileManager.default.removeItem(at: legacyStoreURL)
                logger.info("Migrated session recording store from plaintext to encrypted")
            }
            return migrated
        }

        return [:]
    }

    /// Save a single session→recording mapping, merging with existing entries.
    func save(sessionId: String, entry: RecordingEntry) {
        var map = loadAll()
        map[sessionId] = entry
        write(map)
    }

    /// Persist the full map (encrypted with per-user AES-256-GCM key).
    func write(_ map: [String: RecordingEntry]) {
        guard let encryptor = makeEncryptor(userEmail) else {
            logger.error("Cannot save session recording store: encryption key unavailable")
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let json = try encoder.encode(map)
            let encrypted = try encryptor.encrypt(json)
            try encrypted.write(to: encryptedStoreURL, options: .atomic)
        } catch {
            logger.error("Failed to save session recording map: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers

    private func loadEncrypted() -> [String: RecordingEntry]? {
        guard let encryptor = makeEncryptor(userEmail) else { return nil }
        do {
            let encrypted = try Data(contentsOf: encryptedStoreURL)
            let json = try encryptor.decrypt(encrypted)
            return try JSONDecoder().decode([String: RecordingEntry].self, from: json)
        } catch {
            logger.warning("Failed to decrypt session recording store: \(error.localizedDescription)")
            return nil
        }
    }

    private func loadLegacy() -> [String: RecordingEntry] {
        do {
            let data = try Data(contentsOf: legacyStoreURL)
            return try JSONDecoder().decode([String: RecordingEntry].self, from: data)
        } catch {
            logger.warning("Failed to load legacy session recording map: \(error.localizedDescription)")
            return [:]
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
