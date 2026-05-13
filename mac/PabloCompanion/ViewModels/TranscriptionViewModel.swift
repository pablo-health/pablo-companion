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
    private var audioStore = PendingAudioUploadStore()
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "TranscriptionViewModel")

    /// The signed-in user's email, used to scope encryption keys.
    var userEmail: String? {
        didSet {
            store.userEmail = userEmail
            audioStore.userEmail = userEmail
        }
    }

    // Exponential backoff for audio-upload retries — parity with Windows
    // (TranscriptionViewModel.cs:30-32) and with `retryPendingUploads` below.
    private let audioBaseBackoffSeconds: Double = 300
    private let audioMaxBackoffSeconds: Double = 14400
    private let audioMaxAutoRetries: Int = 10

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
    ///
    /// Persists the upload intent to `PendingAudioUploadStore` BEFORE the
    /// network call so a process crash, sign-out, or network outage leaves
    /// a recovery anchor on disk that `retryPendingAudioUploads` can drain
    /// on the next launch. Mirrors Windows
    /// `TranscriptionViewModel.UploadAudioAsync` (cs:70-115).
    private func uploadAudioToBackend(_ recording: LocalRecording, sessionId: String) async {
        guard let micURL = recording.micPCMFileURL else {
            states[recording.id] = .failed(message: "No mic audio file available")
            return
        }

        // Enqueue BEFORE any network call. Idempotent — re-adding the same
        // sessionId preserves `createdAt` and `retryCount`.
        audioStore.add(
            sessionId: sessionId,
            micPath: micURL.path,
            systemPath: recording.systemPCMFileURL?.path,
            isEncrypted: recording.isEncrypted
        )

        states[recording.id] = .running
        logger.info("Uploading audio to backend for server-side transcription")

        let succeeded = await attemptAudioUpload(
            sessionId: sessionId,
            micPath: micURL.path,
            systemPath: recording.systemPCMFileURL?.path,
            isEncrypted: recording.isEncrypted
        )

        if succeeded {
            audioStore.remove(sessionId: sessionId)
            states[recording.id] = .done(transcript: "")
        } else {
            audioStore.incrementRetry(sessionId: sessionId)
            states[recording.id] = .failed(message: "Audio upload failed — will retry later")
        }
    }

    /// Single upload attempt with INVALID_STATUS self-heal. Returns true on
    /// success. Does NOT touch the pending store — callers manage that.
    /// Path-based so retry flows can call it from `PendingAudioUpload` entries.
    private func attemptAudioUpload(
        sessionId: String,
        micPath: String,
        systemPath: String?,
        isEncrypted: Bool
    ) async -> Bool {
        do {
            let pcm = try decryptPCMIfNeeded(
                micPath: micPath,
                systemPath: systemPath,
                isEncrypted: isEncrypted
            )
            defer { pcm.tempFiles.forEach { RecordingEncryptor.cleanupTempFile($0) } }
            let therapistURL = URL(fileURLWithPath: pcm.micPath)
            let clientURL = pcm.systemPath.map { URL(fileURLWithPath: $0) }

            do {
                let response = try await apiClient.uploadAudio(
                    sessionId: sessionId,
                    therapistAudioURL: therapistURL,
                    clientAudioURL: clientURL,
                    onProgress: { _ in }
                )
                logger.info("Audio upload succeeded: \(response.message ?? "ok")")
                return true
            } catch let PabloError.apiClient(statusCode, message, code)
                where statusCode == 400 && code == "INVALID_STATUS"
            {
                // Backend rejects because the session is still in "recording".
                // Heal: PATCH to recording_complete, retry the upload once.
                logger.warning("Upload returned INVALID_STATUS — attempting self-heal (\(message))")
                _ = try await apiClient.updateSessionStatus(
                    sessionId: sessionId,
                    status: .recordingComplete
                )
                let response = try await apiClient.uploadAudio(
                    sessionId: sessionId,
                    therapistAudioURL: therapistURL,
                    clientAudioURL: clientURL,
                    onProgress: { _ in }
                )
                logger.info("Audio upload succeeded after self-heal: \(response.message ?? "ok")")
                return true
            }
        } catch {
            logger.error("Audio upload failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Retry every queued audio upload with exponential backoff. Mirrors
    /// `retryPendingUploads` (transcript text) but operates on the audio
    /// pending store. Invoked on app launch and after orphan adoption.
    func retryPendingAudioUploads() async {
        let pending = audioStore.loadAll()
        guard !pending.isEmpty else { return }
        logger.info("Retrying \(pending.count) pending audio upload(s)")

        for item in pending {
            if item.retryCount >= audioMaxAutoRetries {
                logger.info("Skip audio session=\(item.sessionId) retry=\(item.retryCount) (max retries exhausted)")
                continue
            }
            if item.retryCount > 0 {
                let backoff = min(
                    audioMaxBackoffSeconds,
                    audioBaseBackoffSeconds * pow(2.0, Double(item.retryCount - 1))
                )
                if Date().timeIntervalSince(item.createdAt) < backoff {
                    logger.info("Skip audio session=\(item.sessionId) retry=\(item.retryCount) (backoff)")
                    continue
                }
            }

            let ok = await attemptAudioUpload(
                sessionId: item.sessionId,
                micPath: item.micPath,
                systemPath: item.systemPath,
                isEncrypted: item.isEncrypted
            )
            if ok {
                audioStore.remove(sessionId: item.sessionId)
            } else {
                audioStore.incrementRetry(sessionId: item.sessionId)
            }
        }
    }

    /// Force-retry every queued audio upload immediately, ignoring backoff and
    /// the max-retries cap. Bound to the Settings "Retry now" entry.
    func forceRetryPendingAudioUploads() async {
        let pending = audioStore.loadAll()
        guard !pending.isEmpty else { return }
        logger.info("Force-retrying \(pending.count) pending audio upload(s)")

        for item in pending {
            let ok = await attemptAudioUpload(
                sessionId: item.sessionId,
                micPath: item.micPath,
                systemPath: item.systemPath,
                isEncrypted: item.isEncrypted
            )
            if ok {
                audioStore.remove(sessionId: item.sessionId)
            } else {
                audioStore.incrementRetry(sessionId: item.sessionId)
            }
        }
    }

    /// Enqueue an audio upload for a session whose recording lives on disk
    /// already (e.g. orphan adoption on launch). Idempotent — re-adding the
    /// same session preserves `createdAt` and `retryCount`.
    func enqueuePendingAudioUpload(
        sessionId: String,
        micPath: String,
        systemPath: String?,
        isEncrypted: Bool
    ) {
        audioStore.add(
            sessionId: sessionId,
            micPath: micPath,
            systemPath: systemPath,
            isEncrypted: isEncrypted
        )
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

    /// Decrypts encrypted PCM sidecar files to temp files for upload. Path-based
    /// so retry / orphan-adoption paths can call it without reconstructing a
    /// `LocalRecording`.
    private func decryptPCMIfNeeded(
        micPath: String,
        systemPath: String?,
        isEncrypted: Bool
    ) throws -> DecryptedPCMPaths {
        var tempFiles: [URL] = []

        let resolvedMic: String
        if isEncrypted {
            let micURL = URL(fileURLWithPath: micPath)
            let tempURL = try RecordingEncryptor.decryptPCMToTempFile(at: micURL, userEmail: userEmail)
            tempFiles.append(tempURL)
            resolvedMic = tempURL.path
            logger.info("Decrypted mic PCM to temp file")
        } else {
            resolvedMic = micPath
        }

        let resolvedSystem: String?
        if isEncrypted, let systemPath {
            let systemURL = URL(fileURLWithPath: systemPath)
            let tempURL = try RecordingEncryptor.decryptPCMToTempFile(at: systemURL, userEmail: userEmail)
            tempFiles.append(tempURL)
            resolvedSystem = tempURL.path
            logger.info("Decrypted system PCM to temp file")
        } else {
            resolvedSystem = systemPath
        }

        return DecryptedPCMPaths(
            micPath: resolvedMic,
            systemPath: resolvedSystem,
            tempFiles: tempFiles
        )
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
