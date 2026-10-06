import CompanionSessionCore
import Foundation
import os

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
///   3. On upload failure: the entry stays queued in `PendingAudioUploadStore`
///   4. `retryPendingAudioUploads()` — drains it on launch and every 5 minutes
@MainActor
@Observable
final class TranscriptionViewModel {
    // MARK: - State

    /// Transcription state keyed by recording ID.
    var states: [UUID: TranscriptionState] = [:]

    /// Number of transcripts waiting to be uploaded.
    var pendingUploadCount = 0

    /// Sessions whose audio the server hasn't accepted yet, for the main window.
    private(set) var uploadBacklog = UploadBacklog()

    /// True while "Upload Now" is draining the queue.
    private(set) var isUploadingNow = false

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
    private var audioStore = PendingAudioUploadStore(
        directory: AppPaths.pendingAudioUploads,
        makeEncryptor: { RecordingEncryptor(userEmail: $0) },
        logSubsystem: AppConstants.appBundleID
    )
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "TranscriptionViewModel")

    /// The signed-in user's email, used to scope encryption keys.
    var userEmail: String? {
        didSet {
            audioStore.userEmail = userEmail
        }
    }

    /// The upload queue, for discarding a session the client declined on the
    /// recording (`RecordingViewModel.discardDeclinedSession`).
    var pendingAudioStore: PendingAudioUploadStore {
        audioStore
    }

    // Exponential backoff for audio-upload retries — parity with Windows
    // (TranscriptionViewModel.cs:30-32).
    private let audioBaseBackoffSeconds: Double = 300
    private let audioMaxBackoffSeconds: Double = 14400
    private let audioMaxAutoRetries = 10
    /// One for the life of the app: `coordinator` is rebuilt on every access,
    /// so the in-flight set has to live here or each drain would get its own.
    private let inFlightUploads = InFlightUploads()

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
        Task { await uploadAudioToBackend([recording], sessionId: sessionId) }
    }

    /// Uploads every segment of a session's recording, in order, as one upload.
    func uploadAudioSegments(_ recordings: [LocalRecording], sessionId: String) async {
        guard autoTranscribe else { return }
        let viable = recordings.filter { $0.micPCMFileURL != nil }
        guard !viable.isEmpty else { return }
        await uploadAudioToBackend(viable, sessionId: sessionId)
    }

    /// Uploads the therapist (mic) and client (system) audio to the backend.
    ///
    /// Persists the upload intent to `PendingAudioUploadStore` BEFORE the
    /// network call so a process crash, sign-out, or network outage leaves
    /// a recovery anchor on disk that `retryPendingAudioUploads` can drain
    /// on the next launch. Mirrors Windows
    /// `TranscriptionViewModel.UploadAudioAsync` (cs:70-115).
    ///
    /// - Parameter segments: the session's recordings in recording order. The
    ///   queue holds them all under the one session, and the drain joins them
    ///   into one file per channel (`SessionAudioStager`).
    private func uploadAudioToBackend(_ segments: [LocalRecording], sessionId: String) async {
        let ids = segments.map(\.id)
        // Enqueue BEFORE any network call. Idempotent — re-adding a queued
        // segment preserves `createdAt` and `retryCount`.
        for recording in segments {
            guard let micURL = recording.micPCMFileURL else {
                states[recording.id] = .failed(message: "No mic audio file available")
                return
            }
            audioStore.add(
                sessionId: sessionId,
                micPath: micURL.path,
                systemPath: recording.systemPCMFileURL?.path,
                isEncrypted: recording.isEncrypted,
                sampleRate: recording.sampleRate
            )
        }

        // Cheap read-only liveness probe before moving the audio. If the
        // server-side session has already idled out, the upload can only 401 —
        // surface the re-auth flow now (verifySessionAlive fires it) and leave
        // the entry queued. It drains via the retry loop after sign-in.
        guard await apiClient.verifySessionAlive() else {
            setStates(ids, .failed(message: "Session expired — sign in to resume the upload"))
            logger.warning("Skipping audio upload: server session is no longer active")
            refreshPendingCounts()
            return
        }

        setStates(ids, .running)
        logger.info("Uploading audio to backend for server-side transcription")

        // Same drain the retry loop uses, so the live path cannot diverge from
        // it — and so a successful upload here deletes the audio too.
        let succeeded = await coordinator.forceDrain(only: sessionId) == 1

        if succeeded {
            setStates(ids, .done(transcript: ""))
        } else {
            setStates(ids, .failed(message: "Audio upload failed — will retry later"))
        }
        refreshPendingCounts()
    }

    private func setStates(_ ids: [UUID], _ state: TranscriptionState) {
        for id in ids {
            states[id] = state
        }
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
                RecordingCleaner.removeAudio(of: entry.segments)
            },
            checkOutcome: { [apiClient] sessionId in
                // Local audio is PHI; it is deleted only once the backend has
                // produced the note, never merely because the upload was
                // accepted. A transient backend failure that once deleted the
                // audio on the ack left the session unrecoverable.
                let session = try await apiClient.fetchSession(sessionId: sessionId)
                switch session.status {
                case .pendingReview, .finalized:
                    return .noteReady
                case .failed:
                    return .failed
                default:
                    // transcribing / queued / processing / anything mid-flight
                    return .stillWorking
                }
            },
            inFlight: inFlightUploads,
            logSubsystem: AppConstants.appBundleID
        )
    }

    /// One upload attempt. Throws on failure so the coordinator can count the
    /// retry; the `INVALID_STATUS` self-heal lives in `AudioUploadClient`.
    private func upload(_ entry: PendingAudioUploadStore.PendingAudioUpload) async throws {
        let email = userEmail
        let staged = try SessionAudioStager.stage(
            entry.segments,
            fallbackRate: Self.fallbackSampleRate,
            decrypt: { path in
                guard entry.isEncrypted else { return (URL(fileURLWithPath: path), false) }
                let url = try RecordingEncryptor.decryptPCMToTempFile(
                    at: URL(fileURLWithPath: path),
                    userEmail: email
                )
                return (url, true)
            }
        )
        defer { staged.tempFiles.forEach { RecordingEncryptor.cleanupTempFile($0) } }

        _ = try await apiClient.uploadAudioWithSelfHeal(
            sessionId: entry.sessionId,
            therapistAudioURL: staged.micURL,
            clientAudioURL: staged.systemURL,
            // The capture rate is negotiated at runtime (Bluetooth HFP can drop
            // the mic to 8/16/24 kHz), so stamp the WAV with the rate the
            // capture actually used, not a hardcoded 48 kHz. A joined session
            // is at the rate every segment was brought to.
            sampleRate: Int(staged.sampleRate),
            onProgress: { _ in }
        )
    }

    /// Drain due entries. Invoked on launch, on a 5-minute timer, and after
    /// orphan adoption.
    func retryPendingAudioUploads() async {
        let coordinator = coordinator
        let drained = await coordinator.drain()
        if drained > 0 {
            logger.info("Drained \(drained) pending audio upload(s)")
        }
        // Same cadence: check whether any already-uploaded session now has its
        // note, so the audio can finally be deleted (or re-queued on failure).
        let confirmed = await coordinator.reconcile()
        if confirmed > 0 {
            logger.info("Confirmed \(confirmed) note(s); deleted local audio")
        }
        refreshPendingCounts()
    }

    /// Retry everything now, ignoring backoff and the retry cap. Bound to the
    /// Settings "Retry now" entry and the main window's "Upload Now", where
    /// waiting out a ladder the user just overrode would be wrong.
    func forceRetryPendingAudioUploads() async {
        guard !isUploadingNow else { return }
        isUploadingNow = true
        defer { isUploadingNow = false }
        let drained = await coordinator.forceDrain()
        logger.info("Force-drained \(drained) pending audio upload(s)")
        refreshPendingCounts()
    }

    /// Re-reads the queue into `pendingUploadCount` and `uploadBacklog`.
    func refreshPendingCounts() {
        let entries = audioStore.loadAll()
        pendingUploadCount = entries.count
        uploadBacklog = UploadBacklog(entries: entries)
    }

    /// Enqueue an audio upload for a session whose recording lives on disk
    /// already (e.g. orphan adoption on launch). Idempotent — re-adding the
    /// same session preserves `createdAt` and `retryCount`.
    /// - Parameter sampleRate: `nil` for a recording adopted off disk, whose
    ///   capture rate is not recoverable from headerless PCM. The retry then
    ///   falls back to `fallbackSampleRate`.
    /// Repoints queued uploads at audio that moved out of a legacy directory.
    func relocateQueuedAudio(from legacy: URL, to dir: URL) {
        audioStore.relocateAudio(from: legacy, to: dir)
    }

    func enqueuePendingAudioUpload(
        sessionId: String,
        micPath: String,
        systemPath: String?,
        mixedPath: String? = nil,
        isEncrypted: Bool,
        sampleRate: Double? = nil
    ) {
        audioStore.add(
            sessionId: sessionId,
            micPath: micPath,
            systemPath: systemPath,
            mixedPath: mixedPath,
            isEncrypted: isEncrypted,
            sampleRate: sampleRate
        )
    }
}
