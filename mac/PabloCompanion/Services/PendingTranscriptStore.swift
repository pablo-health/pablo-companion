import CryptoKit
import Foundation
import os

/// Persists transcripts that have not yet been uploaded to the backend.
///
/// Each pending transcript is written as AES-256-GCM encrypted JSON to
/// `~/Library/Application Support/PabloCompanion/PendingTranscripts/`.
/// No plain-text PHI ever touches the filesystem.
struct PendingTranscriptStore {
    // MARK: - Types

    struct PendingTranscript: Codable {
        let recordingID: UUID
        let sessionID: String
        let text: String
        let createdAt: Date
        var retryCount: Int
    }

    // MARK: - Private

    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "PendingTranscriptStore")

    private var storeDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        let dir = appSupport
            .appendingPathComponent("PabloCompanion", isDirectory: true)
            .appendingPathComponent("PendingTranscripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Public API

    /// Encrypt and save a pending transcript. Overwrites any existing entry for the same recording.
    func save(_ pending: PendingTranscript) {
        guard let encryptor = RecordingEncryptor() else {
            logger.error("Cannot save pending transcript: encryption key unavailable")
            return
        }
        do {
            let json = try JSONEncoder().encode(pending)
            let encrypted = try encryptor.encrypt(json)
            let url = fileURL(for: pending.recordingID)
            try encrypted.write(to: url, options: .atomic)
            logger.debug("Saved pending transcript for \(pending.recordingID)")
        } catch {
            logger.error("Failed to save pending transcript: \(error.localizedDescription)")
        }
    }

    /// Load and decrypt all pending transcripts from disk.
    func loadAll() -> [PendingTranscript] {
        guard let encryptor = RecordingEncryptor() else { return [] }
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
                return try JSONDecoder().decode(PendingTranscript.self, from: json)
            } catch {
                logger.warning("Skipping unreadable pending transcript at \(url.lastPathComponent)")
                return nil
            }
        }
    }

    /// Delete the pending transcript for a recording (call after successful upload).
    func delete(recordingID: UUID) {
        let url = fileURL(for: recordingID)
        try? FileManager.default.removeItem(at: url)
        logger.debug("Deleted pending transcript for \(recordingID)")
    }

    // MARK: - Private

    private func fileURL(for recordingID: UUID) -> URL {
        storeDirectory.appendingPathComponent("\(recordingID).enc")
    }
}
