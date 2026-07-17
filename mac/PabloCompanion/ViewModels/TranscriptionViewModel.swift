import CompanionSessionCore
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
                let onAuthRejected = apiClient.onAuthRejected
                apiClient = APIClient(baseURL: backendURL)
                apiClient.getToken = token
                apiClient.onAuthRejected = onAuthRejected
            }
        }
    }

    // MARK: - Private

    private var apiClient = APIClient()
    private var store = PendingTranscriptStore(makeEncryptor: { RecordingEncryptor(userEmail: $0) })
    private var audioStore = PendingAudioUploadStore(
        directory: AppPaths.pendingAudioUploads,
        makeEncryptor: { RecordingEncryptor(userEmail: $0) },
        logSubsystem: AppConstants.appBundleID
    )
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
    private let audioMaxAutoRetries = 10

    /// Rate assumed for entries queued before `sampleRate` was persisted. Raw
    /// PCM has no header to recover the real rate from, so a legacy entry can
    /// only be guessed — 48 kHz matches what the app assumed unconditionally
    /// before the capture rate was plumbed through.
    private static let fallbackSampleRate: Double = 48000

    private var autoTranscribe: Bool {
        UserDefaults.standard.object(forKey: "autoTranscribe") as? Bool ?? true
    }

    /// Configures the API client with a token provider for authenticated
    /// requests and an optional handler for server-side session rejection.
    func configureAuth(
        getToken: @escaping @Sendable () async throws -> String,
        onAuthRejected: ((Bool) -> Void)? = nil
    ) {
        apiClient.getToken = getToken
        apiClient.onAuthRejected = onAuthRejected
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
            isEncrypted: recording.isEncrypted,
            sampleRate: recording.sampleRate
        )

        // Cheap read-only liveness probe before moving the audio. If the
        // server-side session has already idled out, the upload can only 401 —
        // surface the re-auth flow now (verifySessionAlive fires it) and leave
        // the entry queued. It drains via the retry loop after sign-in.
        guard await apiClient.verifySessionAlive() else {
            states[recording.id] = .failed(message: "Session expired — sign in to resume the upload")
            logger.warning("Skipping audio upload: server session is no longer active")
            return
        }

        states[recording.id] = .running
        logger.info("Uploading audio to backend for server-side transcription")

        // Same drain the retry loop uses, so the live path cannot diverge from
        // it — and so a successful upload here deletes the audio too.
        let succeeded = await coordinator.forceDrain(only: sessionId) == 1

        if succeeded {
            states[recording.id] = .done(transcript: "")
        } else {
            states[recording.id] = .failed(message: "Audio upload failed — will retry later")
        }
        pendingUploadCount = audioStore.loadAll().count
    }

    /// The tested drain: backoff ladder, retry cap, and cleanup after a
    /// confirmed upload all live in `CompanionSessionCore` so the harness and
    /// `swift test` can drive them without launching this app.
    private var coordinator: PendingAudioUploadCoordinator {
        PendingAudioUploadCoordinator(
            store: audioStore,
            policy: .init(
                baseBackoffSeconds: audioBaseBackoffSeconds,
                maxBackoffSeconds: audioMaxBackoffSeconds,
                maxAutoRetries: audioMaxAutoRetries
            ),
            upload: { entry in
                try await self.upload(entry)
            },
            cleanup: { entry in
                RecordingCleaner.removeAudio(micPath: entry.micPath, systemPath: entry.systemPath)
            },
            logSubsystem: AppConstants.appBundleID
        )
    }

    /// One upload attempt. Throws on failure so the coordinator can count the
    /// retry; the `INVALID_STATUS` self-heal lives in `AudioUploadClient`.
    private func upload(_ entry: PendingAudioUploadStore.PendingAudioUpload) async throws {
        let pcm = try decryptPCMIfNeeded(
            micPath: entry.micPath,
            systemPath: entry.systemPath,
            isEncrypted: entry.isEncrypted
        )
        defer { pcm.tempFiles.forEach { RecordingEncryptor.cleanupTempFile($0) } }

        _ = try await apiClient.uploadAudioWithSelfHeal(
            sessionId: entry.sessionId,
            therapistAudioURL: URL(fileURLWithPath: pcm.micPath),
            clientAudioURL: pcm.systemPath.map { URL(fileURLWithPath: $0) },
            // The capture rate is negotiated at runtime (Bluetooth HFP can drop
            // the mic to 8/16/24 kHz), so stamp the WAV with the rate the
            // capture actually used, not a hardcoded 48 kHz.
            sampleRate: Int(entry.sampleRate ?? Self.fallbackSampleRate),
            onProgress: { _ in }
        )
    }

    /// Drain due entries. Invoked on launch, on a 5-minute timer, and after
    /// orphan adoption.
    func retryPendingAudioUploads() async {
        let drained = await coordinator.drain()
        if drained > 0 {
            logger.info("Drained \(drained) pending audio upload(s)")
        }
        pendingUploadCount = audioStore.loadAll().count
    }

    /// Retry everything now, ignoring backoff and the retry cap. Bound to the
    /// Settings "Retry now" entry, where waiting out a ladder the user just
    /// overrode would be wrong.
    func forceRetryPendingAudioUploads() async {
        let drained = await coordinator.forceDrain()
        logger.info("Force-drained \(drained) pending audio upload(s)")
        pendingUploadCount = audioStore.loadAll().count
    }

    /// Enqueue an audio upload for a session whose recording lives on disk
    /// already (e.g. orphan adoption on launch). Idempotent — re-adding the
    /// same session preserves `createdAt` and `retryCount`.
    /// - Parameter sampleRate: `nil` for a recording adopted off disk, whose
    ///   capture rate is not recoverable from headerless PCM. The retry then
    ///   falls back to `fallbackSampleRate`.
    func enqueuePendingAudioUpload(
        sessionId: String,
        micPath: String,
        systemPath: String?,
        isEncrypted: Bool,
        sampleRate: Double? = nil
    ) {
        audioStore.add(
            sessionId: sessionId,
            micPath: micPath,
            systemPath: systemPath,
            isEncrypted: isEncrypted,
            sampleRate: sampleRate
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
