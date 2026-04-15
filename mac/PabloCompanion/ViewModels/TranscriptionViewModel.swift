import Foundation
import os

// MARK: - DecryptedPCMPaths

/// Resolved paths after decrypting encrypted PCM sidecars for upload.
private struct DecryptedPCMPaths {
    let micPath: String
    let systemPath: String?
    let tempFiles: [URL]
}

// MARK: - TranscriptionState

enum TranscriptionState: Sendable {
    case running
    case done(transcript: String)
    case pendingUpload(transcript: String)
    case failed(message: String)

    var transcript: String? {
        switch self {
        case let .done(text), let .pendingUpload(text): text
        default: nil
        }
    }

    var isPendingUpload: Bool {
        if case .pendingUpload = self { return true }
        return false
    }
}

// MARK: - TranscriptionViewModel

/// Orchestrates cloud-based transcription after a session ends.
///
/// Flow:
///   1. `transcribeIfNeeded(_:)` — checks auto-transcribe setting, uploads audio
///   2. Uploads mic + system audio to the backend for server-side transcription
///   3. On upload failure: saves encrypted pending file (retry queue)
///   4. `retryPendingUploads()` — called on app launch to flush the queue
@MainActor
@Observable
final class TranscriptionViewModel {
    // MARK: - State

    /// Transcription state keyed by recording ID.
    var states: [UUID: TranscriptionState] = [:]

    /// Number of transcripts waiting to be uploaded.
    var pendingUploadCount = 0

    var errorMessage: String?
    var showError = false

    // MARK: - Dependencies

    var backendURL = "" {
        didSet {
            if URLValidator.validateScheme(backendURL) == nil {
                let token = apiClient.getToken
                apiClient = APIClient(baseURL: backendURL)
                apiClient.getToken = token
            }
        }
    }

    // MARK: - Private

    private var apiClient = APIClient()
    private var store = PendingTranscriptStore()
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "TranscriptionViewModel")

    /// The signed-in user's email, used to scope encryption keys.
    var userEmail: String? {
        didSet { store.userEmail = userEmail }
    }

    private var autoTranscribe: Bool {
        UserDefaults.standard.object(forKey: "autoTranscribe") as? Bool ?? true
    }

    /// Configures the API client with a token provider for authenticated requests.
    func configureAuth(getToken: @escaping @Sendable () async throws -> String) {
        apiClient.getToken = getToken
    }

    // MARK: - Public API

    /// Triggers cloud transcription for a recording if auto-transcribe is enabled.
    func transcribeIfNeeded(_ recording: LocalRecording, sessionId: String? = nil) {
        guard autoTranscribe else { return }
        guard recording.micPCMFileURL != nil else {
            logger.info("Skipping transcription: no PCM sidecar")
            return
        }
        guard let sessionId else {
            logger.info("Skipping cloud transcription: no session ID")
            return
        }
        Task { await uploadAudioToBackend(recording, sessionId: sessionId) }
    }

    /// Uploads audio files for a set of recordings to the backend for server-side transcription.
    func uploadAudioSegments(_ recordings: [LocalRecording], sessionId: String) async {
        guard autoTranscribe else { return }
        let viable = recordings.filter { $0.micPCMFileURL != nil }
        guard !viable.isEmpty else { return }

        // For cloud upload, use the last recording's audio files (multi-segment will be
        // concatenated on the backend in a future iteration).
        if let recording = viable.last {
            await uploadAudioToBackend(recording, sessionId: sessionId)
        }
    }

    /// Uploads the therapist (mic) and client (system) audio to the backend.
    private func uploadAudioToBackend(_ recording: LocalRecording, sessionId: String) async {
        guard recording.micPCMFileURL != nil else {
            states[recording.id] = .failed(message: "No mic audio file available")
            return
        }

        states[recording.id] = .running
        logger.info("Uploading audio to backend for server-side transcription")

        do {
            // Decrypt if needed
            let pcm = try decryptPCMIfNeeded(recording)
            defer { pcm.tempFiles.forEach { RecordingEncryptor.cleanupTempFile($0) } }

            let therapistURL = URL(fileURLWithPath: pcm.micPath)
            let clientURL = pcm.systemPath.map { URL(fileURLWithPath: $0) }

            let response = try await apiClient.uploadAudio(
                sessionId: sessionId,
                therapistAudioURL: therapistURL,
                clientAudioURL: clientURL
            ) { _ in
                // Progress callback — could wire to UI in future
            }

            states[recording.id] = .done(transcript: "")
            logger.info("Audio upload succeeded: \(response.message ?? "ok")")
        } catch {
            let message = error.localizedDescription
            states[recording.id] = .failed(message: "Audio upload failed: \(message)")
            logger.error("Audio upload failed: \(message)")
        }
    }

    /// Retry all pending transcripts that failed to upload.
    /// Uses exponential backoff: skips items that have been retried too many times recently.
    /// After 10 retries, stops auto-retrying (manual "Retry Now" still works).
    func retryPendingUploads() async {
        let pending = store.loadAll()
        pendingUploadCount = pending.count
        guard !pending.isEmpty else { return }
        logger.info("Retrying \(pending.count) pending transcript uploads")

        for var item in pending {
            // Exponential backoff: skip items past their retry window
            if item.retryCount > 10 { continue }
            if item.retryCount > 0 {
                let backoffSeconds = min(14400, 300 * Int(pow(2.0, Double(item.retryCount - 1))))
                let elapsed = Date().timeIntervalSince(item.createdAt)
                if elapsed < Double(backoffSeconds) { continue }
            }

            do {
                try await postTranscript(sessionID: item.sessionID, text: item.text)
                store.delete(recordingID: item.recordingID)
                pendingUploadCount = max(0, pendingUploadCount - 1)
                if case let .pendingUpload(text) = states[item.recordingID] {
                    states[item.recordingID] = .done(transcript: text)
                }
                logger.info("Retry upload succeeded")
            } catch {
                item.retryCount += 1
                store.save(item)
                logger.warning("Retry upload failed: \(error.localizedDescription)")
            }
        }
    }

    /// Force-retry all pending uploads immediately, ignoring backoff. Called by the "Retry Now" button.
    func forceRetryPendingUploads() async {
        let pending = store.loadAll()
        pendingUploadCount = pending.count
        guard !pending.isEmpty else { return }
        logger.info("Force-retrying \(pending.count) pending transcript uploads")

        for var item in pending {
            do {
                try await postTranscript(sessionID: item.sessionID, text: item.text)
                store.delete(recordingID: item.recordingID)
                pendingUploadCount = max(0, pendingUploadCount - 1)
                if case let .pendingUpload(text) = states[item.recordingID] {
                    states[item.recordingID] = .done(transcript: text)
                }
                logger.info("Force retry upload succeeded")
            } catch {
                item.retryCount += 1
                store.save(item)
                logger.warning("Force retry upload failed: \(error.localizedDescription)")
            }
        }
    }

    /// Re-uploads an existing transcript to the backend (e.g. after a backend processing bug fix).
    func reuploadTranscript(recordingId: UUID, sessionId: String) async {
        guard let text = states[recordingId]?.transcript else {
            logger.warning("No transcript text found for re-upload")
            return
        }
        logger.info("Re-uploading transcript")
        do {
            try await postTranscript(sessionID: sessionId, text: text)
            logger.info("Re-upload succeeded")
        } catch {
            logger.error("Re-upload failed: \(error.localizedDescription)")
            errorMessage = "Re-upload failed: \(error.localizedDescription)"
            showError = true
        }
    }

    // MARK: - Private

    /// Decrypts encrypted PCM sidecar files to temp files for upload.
    private func decryptPCMIfNeeded(
        _ recording: LocalRecording
    ) throws -> DecryptedPCMPaths {
        var tempFiles: [URL] = []

        let micPath: String
        if recording.isEncrypted, let micURL = recording.micPCMFileURL {
            let tempURL = try RecordingEncryptor.decryptPCMToTempFile(at: micURL, userEmail: userEmail)
            tempFiles.append(tempURL)
            micPath = tempURL.path
            logger.info("Decrypted mic PCM to temp file")
        } else {
            micPath = recording.micPCMFileURL?.path ?? ""
        }

        let systemPath: String?
        if recording.isEncrypted, let systemURL = recording.systemPCMFileURL {
            let tempURL = try RecordingEncryptor.decryptPCMToTempFile(at: systemURL, userEmail: userEmail)
            tempFiles.append(tempURL)
            systemPath = tempURL.path
            logger.info("Decrypted system PCM to temp file")
        } else {
            systemPath = recording.systemPCMFileURL?.path
        }

        return DecryptedPCMPaths(micPath: micPath, systemPath: systemPath, tempFiles: tempFiles)
    }

    private func postTranscript(sessionID: String, text: String) async throws {
        _ = try await apiClient.uploadTranscript(
            sessionId: sessionID,
            format: "txt",
            content: text
        )
        logger.info("Transcript POST succeeded")
    }
}
