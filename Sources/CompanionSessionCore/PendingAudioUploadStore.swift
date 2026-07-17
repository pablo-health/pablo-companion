import Foundation

#if canImport(os)
import os
#endif

/// Persists session audio that has not yet been uploaded to the backend.
///
/// Mirrors the Windows `PendingTranscriptionStore` so a failed audio upload
/// on macOS survives a process crash, sign-out, or network outage — the
/// recording stays queued and the launch-time retry loop drains it next
/// time. Distinct from `PendingTranscriptStore`, which queues transcript
/// *text* (no longer used by the cloud-only path but kept for legacy items).
///
/// Each pending entry is written as AES-256-GCM encrypted JSON to
/// `~/Library/Application Support/PabloCompanion/PendingAudioUploads/`.
/// Keyed by `sessionId` (re-adding the same session overwrites).
public struct PendingAudioUploadStore: Sendable {
    // MARK: - Types

    public struct PendingAudioUpload: Codable, Sendable {
        public let sessionId: String
        public let micPath: String
        public let systemPath: String?
        public let isEncrypted: Bool
        public let createdAt: Date
        public var retryCount: Int
        /// Capture rate of the sidecar, stamped into the WAV header at upload.
        ///
        /// Optional because entries queued before this field existed are already
        /// on disk; decoding must not fail on them or a pending upload would be
        /// dropped. `nil` falls back to 48 kHz — raw PCM carries no header to
        /// recover the true rate from, so a legacy entry can only be guessed at,
        /// which is what the pre-#103 code did unconditionally.
        public var sampleRate: Double?
    }

    // MARK: - Configuration

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
        logger = Logger(subsystem: logSubsystem, category: "PendingAudioUploadStore")
        #endif
    }

    /// Where entries live. Injected rather than derived from Application
    /// Support so tests get a temp directory of their own — the suites
    /// previously shared one real directory, and `loadAll` decrypts whatever it
    /// finds there, so isolation depended on each test happening to hold a
    /// different key.
    private let directory: URL

    #if canImport(os)
    private let logger: Logger
    #endif

    private var storeDirectory: URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Public API

    /// Enqueue an audio upload. Overwrites any existing entry for the same session.
    public func add(
        sessionId: String,
        micPath: String,
        systemPath: String?,
        isEncrypted: Bool,
        sampleRate: Double?
    ) {
        let existing = get(sessionId: sessionId)
        let pending = PendingAudioUpload(
            sessionId: sessionId,
            micPath: micPath,
            systemPath: systemPath,
            isEncrypted: isEncrypted,
            createdAt: existing?.createdAt ?? Date(),
            retryCount: existing?.retryCount ?? 0,
            sampleRate: sampleRate
        )
        save(pending)
    }

    /// Encrypt and write a pending entry to disk.
    public func save(_ pending: PendingAudioUpload) {
        guard let encryptor = makeEncryptor(userEmail) else {
            #if canImport(os)
            logger.error("Cannot save pending audio upload: encryption key unavailable")
            #endif
            return
        }
        do {
            let json = try JSONEncoder().encode(pending)
            let encrypted = try encryptor.encrypt(json)
            try encrypted.write(to: fileURL(for: pending.sessionId), options: .atomic)
            #if canImport(os)
            logger.debug("Saved pending audio upload for session \(pending.sessionId)")
            #endif
        } catch {
            #if canImport(os)
            logger.error("Failed to save pending audio upload: \(error.localizedDescription)")
            #endif
        }
    }

    /// Load and decrypt every pending entry from disk.
    public func loadAll() -> [PendingAudioUpload] {
        guard let encryptor = makeEncryptor(userEmail) else { return [] }
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: storeDirectory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "enc" }
        } catch {
            return []
        }
        return urls.compactMap { url in
            do {
                let encrypted = try Data(contentsOf: url)
                let json = try encryptor.decrypt(encrypted)
                return try JSONDecoder().decode(PendingAudioUpload.self, from: json)
            } catch {
                #if canImport(os)
                logger.warning("Skipping unreadable pending audio upload at \(url.lastPathComponent)")
                #endif
                return nil
            }
        }
    }

    /// Look up a single pending entry by session ID.
    public func get(sessionId: String) -> PendingAudioUpload? {
        guard let encryptor = makeEncryptor(userEmail) else { return nil }
        let url = fileURL(for: sessionId)
        guard let encrypted = try? Data(contentsOf: url),
              let json = try? encryptor.decrypt(encrypted),
              let pending = try? JSONDecoder().decode(PendingAudioUpload.self, from: json)
        else { return nil }
        return pending
    }

    /// Remove a pending entry (call after the upload succeeds).
    public func remove(sessionId: String) {
        try? FileManager.default.removeItem(at: fileURL(for: sessionId))
        #if canImport(os)
        logger.debug("Removed pending audio upload for session \(sessionId)")
        #endif
    }

    /// Increment `retryCount` for an existing entry. No-op if missing.
    public func incrementRetry(sessionId: String) {
        guard var pending = get(sessionId: sessionId) else { return }
        pending.retryCount += 1
        save(pending)
    }

    // MARK: - Private

    /// `sessionId` is a UUID string from the backend; encode it for filesystem safety.
    private func fileURL(for sessionId: String) -> URL {
        let safe = sessionId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? sessionId
        return storeDirectory.appendingPathComponent("\(safe).enc")
    }
}
