import CryptoKit
import Foundation
import os

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
struct PendingAudioUploadStore {
    // MARK: - Types

    struct PendingAudioUpload: Codable {
        let sessionId: String
        let micPath: String
        let systemPath: String?
        let isEncrypted: Bool
        let createdAt: Date
        var retryCount: Int
        /// Capture rate of the sidecar, stamped into the WAV header at upload.
        ///
        /// Optional because entries queued before this field existed are already
        /// on disk; decoding must not fail on them or a pending upload would be
        /// dropped. `nil` falls back to 48 kHz — raw PCM carries no header to
        /// recover the true rate from, so a legacy entry can only be guessed at,
        /// which is what the pre-#103 code did unconditionally.
        var sampleRate: Double?
    }

    // MARK: - Configuration

    /// User email for per-user encryption key scoping. Set after sign-in.
    var userEmail: String?

    /// Source of the AES key entries are sealed with. Defaults to the Keychain;
    /// tests inject an in-memory provider so they neither prompt for access nor
    /// leave keys in the developer's login Keychain.
    var keyProvider: EncryptionKeyProviding = KeychainEncryptionKeyProvider()

    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "PendingAudioUploadStore")

    private var storeDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        let dir = appSupport
            .appendingPathComponent("PabloCompanion", isDirectory: true)
            .appendingPathComponent("PendingAudioUploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Public API

    /// Enqueue an audio upload. Overwrites any existing entry for the same session.
    func add(
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
    func save(_ pending: PendingAudioUpload) {
        guard let encryptor = RecordingEncryptor(userEmail: userEmail, keyProvider: keyProvider) else {
            logger.error("Cannot save pending audio upload: encryption key unavailable")
            return
        }
        do {
            let json = try JSONEncoder().encode(pending)
            let encrypted = try encryptor.encrypt(json)
            try encrypted.write(to: fileURL(for: pending.sessionId), options: .atomic)
            logger.debug("Saved pending audio upload for session \(pending.sessionId)")
        } catch {
            logger.error("Failed to save pending audio upload: \(error.localizedDescription)")
        }
    }

    /// Load and decrypt every pending entry from disk.
    func loadAll() -> [PendingAudioUpload] {
        guard let encryptor = RecordingEncryptor(userEmail: userEmail, keyProvider: keyProvider) else { return [] }
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
                logger.warning("Skipping unreadable pending audio upload at \(url.lastPathComponent)")
                return nil
            }
        }
    }

    /// Look up a single pending entry by session ID.
    func get(sessionId: String) -> PendingAudioUpload? {
        guard let encryptor = RecordingEncryptor(userEmail: userEmail, keyProvider: keyProvider) else { return nil }
        let url = fileURL(for: sessionId)
        guard let encrypted = try? Data(contentsOf: url),
              let json = try? encryptor.decrypt(encrypted),
              let pending = try? JSONDecoder().decode(PendingAudioUpload.self, from: json)
        else { return nil }
        return pending
    }

    /// Remove a pending entry (call after the upload succeeds).
    func remove(sessionId: String) {
        try? FileManager.default.removeItem(at: fileURL(for: sessionId))
        logger.debug("Removed pending audio upload for session \(sessionId)")
    }

    /// Increment `retryCount` for an existing entry. No-op if missing.
    func incrementRetry(sessionId: String) {
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
