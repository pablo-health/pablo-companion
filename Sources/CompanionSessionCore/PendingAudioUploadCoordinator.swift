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
    public typealias CleanupAttempt = @Sendable (_ sessionId: String) -> Void

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
    private let now: @Sendable () -> Date

    #if canImport(os)
    private let logger: Logger
    #endif

    /// - Parameter now: injected so a test can age an entry past its backoff
    ///   instead of waiting out a four-hour ladder in real time.
    public init(
        store: PendingAudioUploadStore,
        policy: Policy = Policy(),
        upload: @escaping UploadAttempt,
        cleanup: @escaping CleanupAttempt,
        now: @escaping @Sendable () -> Date = { Date() },
        logSubsystem: String = "health.pablo.companion"
    ) {
        self.store = store
        self.policy = policy
        self.upload = upload
        self.cleanup = cleanup
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
    @discardableResult
    public func drain() async -> Int {
        await drain(entries: store.loadAll().filter(isDue))
    }

    /// Attempt every entry regardless of backoff or the retry cap. Bound to the
    /// user-initiated "Retry now" affordance, where waiting out a ladder the
    /// user is explicitly overriding would be wrong.
    @discardableResult
    public func forceDrain() async -> Int {
        await drain(entries: store.loadAll())
    }

    private func drain(entries: [PendingAudioUploadStore.PendingAudioUpload]) async -> Int {
        guard !entries.isEmpty else { return 0 }
        var succeeded = 0

        for entry in entries {
            do {
                try await upload(entry)
                succeeded += 1
                // Order matters: drop the queue entry first, so a cleanup that
                // throws can never leave a session queued for a re-upload the
                // backend has already accepted.
                store.remove(sessionId: entry.sessionId)
                cleanup(entry.sessionId)
            } catch {
                store.incrementRetry(sessionId: entry.sessionId)
                #if canImport(os)
                logger.error("Audio upload failed for session \(entry.sessionId): \(error.localizedDescription)")
                #endif
            }
        }
        return succeeded
    }
}
