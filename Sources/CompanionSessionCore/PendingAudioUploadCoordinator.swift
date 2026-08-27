import Foundation

#if canImport(os)
import os
#endif

/// Drains the pending audio queue: backoff policy, retry accounting, and the
/// cleanup that follows a confirmed upload.
///
/// This logic used to live in `TranscriptionViewModel`, inside the app target,
/// where nothing could reach it. The e2e harness builds `Sources/` only and
/// never compiles the app, and the app's own unit tests are app-hosted — so
/// exercising a backoff ladder meant launching a window and hoping no Keychain
/// dialog appeared. The result was predictable: a `sampleRate` argument that
/// referenced a variable not in scope shipped to `main` and broke the build,
/// past a green CI, because nothing compiled this path.
///
/// Here it is a plain value type over injected seams, so the harness and
/// `swift test` drive the real code in milliseconds.
public struct PendingAudioUploadCoordinator: Sendable {
    /// Uploads one queued entry. Returns normally on success, throws on failure.
    /// The caller supplies this so the app can route through its `APIClient`
    /// (auth, DPoP, the `INVALID_STATUS` self-heal) while this type stays free
    /// of all of it.
    public typealias UploadAttempt = @Sendable (
        _ entry: PendingAudioUploadStore.PendingAudioUpload
    ) async throws -> Void

    /// Removes a session's audio from disk once the backend has confirmed it.
    ///
    /// Local audio is deleted on confirmed upload rather than retained: it is
    /// PHI on a therapist's laptop with no expiry, and each session is a mixed
    /// WAV plus two PCM sidecars — enough to fill a disk in weeks. Deleting also
    /// makes file-presence the "not yet uploaded" state, which is what stops a
    /// completed session being re-adopted and re-uploaded on every launch.
    ///
    /// A failure here must not fail the upload: the bytes are safely on the
    /// backend, and leaving files behind is recoverable where losing an upload
    /// is not.
    /// Takes the entry, not an id: the queue entry is dropped before cleanup
    /// runs, so anything that tried to look the paths back up by id would find
    /// nothing and silently delete nothing.
    public typealias CleanupAttempt = @Sendable (
        _ entry: PendingAudioUploadStore.PendingAudioUpload
    ) -> Void

    /// What the backend has done with an uploaded session, as far as the note
    /// goes. The app maps its own session status onto this so this type stays
    /// backend-agnostic.
    public enum SessionOutcome: Sendable {
        /// The note exists (`pending_review`/finalized) — safe to delete the audio.
        case noteReady
        /// Transcription failed — keep the audio and re-queue the upload.
        case failed
        /// Still transcribing — leave the entry alone and check again later.
        case stillWorking
    }

    /// Asks the backend where an awaiting-note session stands. Throwing (e.g. a
    /// network blip) is treated as `stillWorking`: the audio is kept and the
    /// check retries, never deleting on an inconclusive answer.
    public typealias OutcomeCheck = @Sendable (_ sessionId: String) async throws -> SessionOutcome

    /// Backoff policy. Matches the Windows `TranscriptionViewModel` constants —
    /// both platforms drain the same queue shape against the same backend, so
    /// they must agree.
    public struct Policy: Sendable {
        public let baseBackoffSeconds: Double
        public let maxBackoffSeconds: Double
        public let maxAutoRetries: Int

        public init(
            baseBackoffSeconds: Double = 300,
            maxBackoffSeconds: Double = 14400,
            maxAutoRetries: Int = 10
        ) {
            self.baseBackoffSeconds = baseBackoffSeconds
            self.maxBackoffSeconds = maxBackoffSeconds
            self.maxAutoRetries = maxAutoRetries
        }
    }

    private let store: PendingAudioUploadStore
    private let policy: Policy
    private let upload: UploadAttempt
    private let cleanup: CleanupAttempt
    private let checkOutcome: OutcomeCheck?
    private let now: @Sendable () -> Date

    #if canImport(os)
    private let logger: Logger
    #endif

    /// - Parameters:
    ///   - checkOutcome: how to ask the backend whether the note is ready. When
    ///     nil, a successful upload deletes the audio immediately (the old
    ///     behaviour) — provided for callers that don't poll. When set, a
    ///     successful upload instead moves the entry to `awaitingNote` and the
    ///     audio is kept until `reconcile()` sees the note.
    ///   - now: injected so a test can age an entry past its backoff instead of
    ///     waiting out a four-hour ladder in real time.
    public init(
        store: PendingAudioUploadStore,
        policy: Policy = Policy(),
        upload: @escaping UploadAttempt,
        cleanup: @escaping CleanupAttempt,
        checkOutcome: OutcomeCheck? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        logSubsystem: String = "health.pablo.companion"
    ) {
        self.store = store
        self.policy = policy
        self.upload = upload
        self.cleanup = cleanup
        self.checkOutcome = checkOutcome
        self.now = now
        #if canImport(os)
        logger = Logger(subsystem: logSubsystem, category: "PendingAudioUploadCoordinator")
        #endif
    }

    /// The delay an entry must sit out before its next attempt. Doubles per
    /// retry from `baseBackoffSeconds`, capped at `maxBackoffSeconds`.
    public func backoff(forRetryCount retryCount: Int) -> Double {
        guard retryCount > 0 else { return 0 }
        return min(
            policy.maxBackoffSeconds,
            policy.baseBackoffSeconds * pow(2.0, Double(retryCount - 1))
        )
    }

    /// Whether an entry is due, honouring the retry cap and the backoff ladder.
    public func isDue(_ entry: PendingAudioUploadStore.PendingAudioUpload) -> Bool {
        guard entry.retryCount < policy.maxAutoRetries else { return false }
        guard entry.retryCount > 0 else { return true }
        return now().timeIntervalSince(entry.createdAt) >= backoff(forRetryCount: entry.retryCount)
    }

    /// Attempt every entry that is due. Called on launch and on a timer.
    /// Only entries still `pendingUpload` are uploaded; `awaitingNote` entries
    /// are left for `reconcile()`.
    @discardableResult
    public func drain() async -> Int {
        await drain(entries: store.loadAll().filter { $0.state == .pendingUpload && isDue($0) })
    }

    /// Attempt every entry regardless of backoff or the retry cap. Bound to the
    /// user-initiated "Retry now" affordance, where waiting out a ladder the
    /// user is explicitly overriding would be wrong.
    ///
    /// - Parameter only: restrict to one session. The just-finished-recording
    ///   path uses this so it runs the same attempt-and-cleanup as the retry
    ///   loop rather than a parallel copy that could drift from it — which it
    ///   previously was, and which is how the live path ended up not deleting
    ///   the audio it had just uploaded.
    @discardableResult
    public func forceDrain(only sessionId: String? = nil) async -> Int {
        let all = store.loadAll().filter { $0.state == .pendingUpload }
        let entries = sessionId.map { id in all.filter { $0.sessionId == id } } ?? all
        return await drain(entries: entries)
    }

    private func drain(entries: [PendingAudioUploadStore.PendingAudioUpload]) async -> Int {
        guard !entries.isEmpty else { return 0 }
        var succeeded = 0

        for entry in entries {
            do {
                try await upload(entry)
                succeeded += 1

                if checkOutcome == nil {
                    // No polling configured: the upload ack is the only signal,
                    // so delete now. Order matters — drop the entry first, so a
                    // cleanup that throws can't leave the session queued for a
                    // re-upload the backend already accepted.
                    store.remove(sessionId: entry.sessionId)
                    cleanup(entry)
                } else {
                    // The upload is accepted, but the backend can still fail to
                    // produce a note. Keep the audio and wait for `reconcile()`
                    // to confirm the note before deleting — deleting on the ack
                    // is what once turned a transient backend race into
                    // permanent loss.
                    store.setState(sessionId: entry.sessionId, .awaitingNote)
                }
            } catch {
                store.incrementRetry(sessionId: entry.sessionId)
                #if canImport(os)
                logger.error("Audio upload failed for session \(entry.sessionId): \(error.localizedDescription)")
                #endif
            }
        }
        return succeeded
    }

    /// Check every awaiting-note entry against the backend and act on the answer:
    /// delete the audio once the note exists, re-queue the upload if the backend
    /// failed, or leave it be while transcription is still running.
    ///
    /// Called on the same cadence as `drain()` — launch and the periodic timer —
    /// so a therapist who closed the app mid-transcription still gets the audio
    /// cleaned up (or recovered) on the next launch. No-op without an
    /// `checkOutcome`.
    @discardableResult
    public func reconcile() async -> Int {
        guard let checkOutcome else { return 0 }
        let awaiting = store.loadAll().filter { $0.state == .awaitingNote }
        guard !awaiting.isEmpty else { return 0 }

        var confirmed = 0
        for entry in awaiting {
            let outcome: SessionOutcome
            do {
                outcome = try await checkOutcome(entry.sessionId)
            } catch {
                // Inconclusive — never delete on a failed check. Keep the audio
                // and try again next cycle.
                #if canImport(os)
                logger.warning("Note-status check failed for session \(entry.sessionId); keeping audio")
                #endif
                continue
            }

            switch outcome {
            case .noteReady:
                store.remove(sessionId: entry.sessionId)
                cleanup(entry)
                confirmed += 1
            case .failed:
                // Back to the upload queue. Reset retry so the backoff ladder
                // starts fresh rather than treating this as a continued failure.
                store.setState(sessionId: entry.sessionId, .pendingUpload)
                store.resetRetry(sessionId: entry.sessionId)
                #if canImport(os)
                logger.info("Session \(entry.sessionId) failed transcription; re-queued for upload")
                #endif
            case .stillWorking:
                break
            }
        }
        return confirmed
    }
}
