import Foundation

#if canImport(os)
import os
#endif

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
public struct SessionRecordingStore: Sendable {
    // MARK: - Types

    public struct RecordingEntry: Codable, Sendable {
        public let recordingID: UUID
        public let fileURL: String
        public let duration: TimeInterval
        public let createdAt: Date
        public let isEncrypted: Bool
        public let checksum: String
        public let channelLayout: String
        public let micPCMFilePath: String?
        public let systemPCMFilePath: String?
        /// Actual sample rate of the PCM sidecar files (may be < 48 kHz with Bluetooth HFP).
        public let sampleRate: Double?

        /// Explicit because a public struct's memberwise init is synthesized
        /// internal — the app builds entries from its own `LocalRecording`
        /// model, which lives on the other side of the module line.
        public init(
            recordingID: UUID,
            fileURL: String,
            duration: TimeInterval,
            createdAt: Date,
            isEncrypted: Bool,
            checksum: String,
            channelLayout: String,
            micPCMFilePath: String?,
            systemPCMFilePath: String?,
            sampleRate: Double?
        ) {
            self.recordingID = recordingID
            self.fileURL = fileURL
            self.duration = duration
            self.createdAt = createdAt
            self.isEncrypted = isEncrypted
            self.checksum = checksum
            self.channelLayout = channelLayout
            self.micPCMFilePath = micPCMFilePath
            self.systemPCMFilePath = systemPCMFilePath
            self.sampleRate = sampleRate
        }
    }

    // MARK: - Private

    /// User email for per-user encryption key scoping. Set after sign-in.
    public var userEmail: String?

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
    public let makeEncryptor: SessionEncryptorFactory

    /// - Parameter makeEncryptor: has no default on purpose. A default of
    ///   `{ RecordingEncryptor(userEmail: $0) }` would name a type that conforms
    ///   to AudioCaptureKit's `CaptureEncryptor` — macOS-only — and re-couple
    ///   this store to it, which is precisely what the abstraction exists to
    ///   avoid. The app supplies the concrete encryptor at construction.
    public init(
        directory: URL,
        makeEncryptor: @escaping SessionEncryptorFactory,
        logSubsystem: String = "health.pablo.companion"
    ) {
        self.directory = directory
        self.makeEncryptor = makeEncryptor
        #if canImport(os)
        logger = Logger(subsystem: logSubsystem, category: "SessionRecordingStore")
        #endif
    }

    /// Where the map lives. Injected rather than derived from Application
    /// Support so tests get their own directory — and so this type stops naming
    /// a macOS-specific location it has no business knowing.
    private let directory: URL

    #if canImport(os)
    private let logger: Logger
    #endif

    private var storeDirectory: URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
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
    public func loadAll() -> [String: RecordingEntry] {
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
                #if canImport(os)
                logger.info("Migrated session recording store from plaintext to encrypted")
                #endif
            }
            return migrated
        }

        return [:]
    }

    /// Save a single session→recording mapping, merging with existing entries.
    public func save(sessionId: String, entry: RecordingEntry) {
        var map = loadAll()
        map[sessionId] = entry
        write(map)
    }

    /// Persist the full map (encrypted with per-user AES-256-GCM key).
    public func write(_ map: [String: RecordingEntry]) {
        guard let encryptor = makeEncryptor(userEmail) else {
            #if canImport(os)
            logger.error("Cannot save session recording store: encryption key unavailable")
            #endif
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let json = try encoder.encode(map)
            let encrypted = try encryptor.encrypt(json)
            try encrypted.write(to: encryptedStoreURL, options: .atomic)
        } catch {
            #if canImport(os)
            logger.error("Failed to save session recording map: \(error.localizedDescription)")
            #endif
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
            #if canImport(os)
            logger.warning("Failed to decrypt session recording store: \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    private func loadLegacy() -> [String: RecordingEntry] {
        do {
            let data = try Data(contentsOf: legacyStoreURL)
            return try JSONDecoder().decode([String: RecordingEntry].self, from: data)
        } catch {
            #if canImport(os)
            logger.warning("Failed to load legacy session recording map: \(error.localizedDescription)")
            #endif
            return [:]
        }
    }

    // MARK: - Convenience
}
