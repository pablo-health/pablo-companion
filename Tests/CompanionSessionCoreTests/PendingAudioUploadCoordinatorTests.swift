import Foundation
import Testing
@testable import CompanionSessionCore

/// Covers the queue drain: backoff, the retry cap, and cleanup after a confirmed
/// upload.
///
/// None of this was testable before the coordinator moved out of the app target
/// — it sat in `TranscriptionViewModel`, reachable only by launching Pablo. That
/// is how a four-hour backoff ladder and a ten-attempt cap shipped with no test
/// at all, and how a compile error in the same function reached `main`.
@Suite("PendingAudioUploadCoordinator drain")
struct PendingAudioUploadCoordinatorTests {

    private static func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("coordinator-\(UUID().uuidString)", isDirectory: true)
    }

    private static func makeStore() -> PendingAudioUploadStore {
        // One encryptor instance, not one per call: the fake mints a random key
        // per instance, so a factory that builds a new one each time would seal
        // with one key and try to read back with another.
        let encryptor = FakeSessionDataEncryptor()
        var store = PendingAudioUploadStore(
            directory: tempDir(),
            makeEncryptor: { _ in encryptor }
        )
        store.userEmail = "therapist@pablo.health"
        return store
    }

    private static func queue(_ store: PendingAudioUploadStore, _ sessionId: String) {
        store.add(
            sessionId: sessionId,
            micPath: "/tmp/\(sessionId)-mic.pcm",
            systemPath: nil,
            isEncrypted: false,
            sampleRate: 48000
        )
    }

    // MARK: - Backoff ladder

    @Test func theFirstAttemptWaitsForNothing() {
        let c = makeCoordinator(store: Self.makeStore())
        #expect(c.backoff(forRetryCount: 0) == 0)
    }

    @Test func backoffDoublesPerRetry() {
        let c = makeCoordinator(store: Self.makeStore())
        #expect(c.backoff(forRetryCount: 1) == 300)
        #expect(c.backoff(forRetryCount: 2) == 600)
        #expect(c.backoff(forRetryCount: 3) == 1200)
    }

    @Test func backoffIsCappedSoItCannotGrowWithoutBound() {
        let c = makeCoordinator(store: Self.makeStore())
        // 300 * 2^19 would be ~6 months; the cap is four hours.
        #expect(c.backoff(forRetryCount: 20) == 14400)
    }

    // MARK: - Due-ness

    @Test func aFreshEntryIsDueImmediately() {
        let store = Self.makeStore()
        Self.queue(store, "session-A")
        let c = makeCoordinator(store: store)
        let entry = store.get(sessionId: "session-A")!

        #expect(c.isDue(entry))
    }

    @Test func anEntryInsideItsBackoffIsNotDue() throws {
        let store = Self.makeStore()
        Self.queue(store, "session-B")
        store.incrementRetry(sessionId: "session-B")
        let entry = try #require(store.get(sessionId: "session-B"))

        // One retry means a 300s wait; only 10s have passed.
        let c = makeCoordinator(store: store, now: { entry.createdAt.addingTimeInterval(10) })

        #expect(!c.isDue(entry))
    }

    @Test func anEntryPastItsBackoffIsDue() throws {
        let store = Self.makeStore()
        Self.queue(store, "session-C")
        store.incrementRetry(sessionId: "session-C")
        let entry = try #require(store.get(sessionId: "session-C"))

        let c = makeCoordinator(store: store, now: { entry.createdAt.addingTimeInterval(301) })

        #expect(c.isDue(entry))
    }

    @Test func anEntryPastTheRetryCapIsNeverDue() throws {
        let store = Self.makeStore()
        Self.queue(store, "session-D")
        for _ in 0 ..< 10 { store.incrementRetry(sessionId: "session-D") }
        let entry = try #require(store.get(sessionId: "session-D"))

        // Far past any backoff — the cap, not the clock, is what stops it.
        let c = makeCoordinator(store: store, now: { entry.createdAt.addingTimeInterval(999_999) })

        #expect(!c.isDue(entry))
    }

    // MARK: - Draining

    @Test func aSuccessfulDrainRemovesTheEntryAndDeletesTheAudio() async throws {
        let store = Self.makeStore()
        Self.queue(store, "session-E")
        let cleaned = Box<[String]>([])
        let c = makeCoordinator(store: store, cleanup: { cleaned.value.append($0.sessionId) })

        let count = await c.drain()

        #expect(count == 1)
        #expect(store.get(sessionId: "session-E") == nil)
        #expect(cleaned.value == ["session-E"])
    }

    @Test func aFailedDrainKeepsTheEntryAndDoesNotDeleteTheAudio() async throws {
        // The durability anchor: a failed upload must leave the recording both
        // queued and on disk, or the session is gone.
        let store = Self.makeStore()
        Self.queue(store, "session-F")
        let cleaned = Box<[String]>([])
        let c = makeCoordinator(
            store: store,
            upload: { _ in throw CoordinatorTestError.uploadFailed },
            cleanup: { cleaned.value.append($0.sessionId) }
        )

        let count = await c.drain()

        #expect(count == 0)
        let entry = try #require(store.get(sessionId: "session-F"))
        #expect(entry.retryCount == 1)
        #expect(cleaned.value.isEmpty)
    }

    @Test func theQueueEntryIsGoneBeforeCleanupRuns() async {
        // Pins the ordering the source says matters: remove-then-cleanup, so a
        // cleanup that misbehaves can never leave a session queued for a
        // re-upload the backend already accepted.
        //
        // Replaces a test that claimed to prove "a failing cleanup still counts
        // the upload as done" — a tautology, since CleanupAttempt is
        // non-throwing and cannot fail.
        let store = Self.makeStore()
        Self.queue(store, "session-G")
        let queuedAtCleanup = Box<Bool?>(nil)
        let c = makeCoordinator(store: store, cleanup: { entry in
            queuedAtCleanup.value = store.get(sessionId: entry.sessionId) != nil
        })

        let count = await c.drain()

        #expect(count == 1)
        #expect(queuedAtCleanup.value == false)
    }

    // MARK: - The live post-recording path

    @Test func forceDrainOnlyAttemptsTheNamedSession() async {
        // TranscriptionViewModel's just-finished-recording path is the only
        // caller of forceDrain(only:), and its filter had zero test executions.
        // Uploading a neighbouring therapist's queued session here would be a
        // real incident.
        let store = Self.makeStore()
        Self.queue(store, "session-A")
        Self.queue(store, "session-B")
        let attempted = Box<[String]>([])
        let c = makeCoordinator(store: store, upload: { attempted.value.append($0.sessionId) })

        let count = await c.forceDrain(only: "session-A")

        #expect(attempted.value == ["session-A"])
        #expect(count == 1)
        #expect(store.get(sessionId: "session-B") != nil)
    }

    @Test func forceDrainWithAnUnknownSessionAttemptsNothing() async {
        let store = Self.makeStore()
        Self.queue(store, "session-A")
        let attempted = Box<[String]>([])
        let c = makeCoordinator(store: store, upload: { attempted.value.append($0.sessionId) })

        let count = await c.forceDrain(only: "session-does-not-exist")

        #expect(attempted.value.isEmpty)
        #expect(count == 0)
    }

    @Test func forceDrainWithNoFilterStillAttemptsEverything() async {
        let store = Self.makeStore()
        Self.queue(store, "session-A")
        Self.queue(store, "session-B")
        let attempted = Box<[String]>([])
        let c = makeCoordinator(store: store, upload: { attempted.value.append($0.sessionId) })

        _ = await c.forceDrain()

        #expect(attempted.value.sorted() == ["session-A", "session-B"])
    }

    // MARK: - Multi-entry behaviour

    @Test func oneFailedEntryDoesNotStopTheRest() async throws {
        // Every other drain test uses a single entry, so a refactor that threw
        // out of the loop on first failure would pass all of them — and one
        // stuck session would block every other therapist upload behind it.
        let store = Self.makeStore()
        Self.queue(store, "session-bad")
        Self.queue(store, "session-good")
        let attempted = Box<[String]>([])
        let c = makeCoordinator(store: store, upload: { entry in
            attempted.value.append(entry.sessionId)
            if entry.sessionId == "session-bad" { throw CoordinatorTestError.uploadFailed }
        })

        let count = await c.drain()

        #expect(attempted.value.sorted() == ["session-bad", "session-good"])
        #expect(count == 1)
        #expect(store.get(sessionId: "session-good") == nil)
        #expect(try #require(store.get(sessionId: "session-bad")).retryCount == 1)
    }

    @Test func theLastAllowedRetryIsStillDue() throws {
        // Boundary: 0, 1 and 10 were pinned; 9 — the last attempt the cap
        // permits — was not.
        let store = Self.makeStore()
        Self.queue(store, "session-9")
        for _ in 0 ..< 9 { store.incrementRetry(sessionId: "session-9") }
        let entry = try #require(store.get(sessionId: "session-9"))
        let c = makeCoordinator(store: store, now: { entry.createdAt.addingTimeInterval(999_999) })

        #expect(entry.retryCount == 9)
        #expect(c.isDue(entry))
    }

    @Test func drainSkipsEntriesInsideTheirBackoff() async throws {
        let store = Self.makeStore()
        Self.queue(store, "session-H")
        store.incrementRetry(sessionId: "session-H")
        let entry = try #require(store.get(sessionId: "session-H"))
        let attempted = Box<[String]>([])

        let c = makeCoordinator(
            store: store,
            upload: { attempted.value.append($0.sessionId) },
            now: { entry.createdAt.addingTimeInterval(5) }
        )

        _ = await c.drain()

        #expect(attempted.value.isEmpty)
    }

    @Test func forceDrainIgnoresBackoffAndTheRetryCap() async throws {
        // "Retry now" is an explicit user override; waiting out a ladder they
        // just overrode would be wrong.
        let store = Self.makeStore()
        Self.queue(store, "session-I")
        for _ in 0 ..< 10 { store.incrementRetry(sessionId: "session-I") }
        let attempted = Box<[String]>([])

        let c = makeCoordinator(store: store, upload: { attempted.value.append($0.sessionId) })

        _ = await c.forceDrain()

        #expect(attempted.value == ["session-I"])
    }

    @Test func cleanupReceivesThePathsNotJustAnID() async {
        // The entry is dropped before cleanup runs, so handing cleanup only an
        // id means anything looking the paths back up finds nothing and deletes
        // nothing — silently, with every other test still green.
        let store = Self.makeStore()
        store.add(
            sessionId: "session-K",
            micPath: "/tmp/session-K-mic.pcm",
            systemPath: "/tmp/session-K-sys.pcm",
            isEncrypted: false,
            sampleRate: 48000
        )
        let paths = Box<[String?]>([])
        let c = makeCoordinator(store: store, cleanup: { entry in
            paths.value.append(entry.micPath)
            paths.value.append(entry.systemPath)
        })

        _ = await c.drain()

        #expect(paths.value == ["/tmp/session-K-mic.pcm", "/tmp/session-K-sys.pcm"])
    }

    @Test func drainingAnEmptyQueueDoesNothing() async {
        let c = makeCoordinator(store: Self.makeStore())
        let count = await c.drain()
        #expect(count == 0)
    }

    @Test func theCaptureRateReachesTheUpload() async throws {
        // The regression that broke main: the rate has to arrive at the upload,
        // and a queued entry is the only place a post-relaunch retry can get it.
        let store = Self.makeStore()
        store.add(
            sessionId: "session-J",
            micPath: "/tmp/m.pcm",
            systemPath: nil,
            isEncrypted: false,
            sampleRate: 24000
        )
        let seen = Box<[Double?]>([])
        let c = makeCoordinator(store: store, upload: { seen.value.append($0.sampleRate) })

        _ = await c.drain()

        #expect(seen.value == [24000])
    }

    // MARK: - Helpers

    private func makeCoordinator(
        store: PendingAudioUploadStore,
        upload: @escaping PendingAudioUploadCoordinator.UploadAttempt = { _ in },
        cleanup: @escaping PendingAudioUploadCoordinator.CleanupAttempt = { _ in },
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> PendingAudioUploadCoordinator {
        PendingAudioUploadCoordinator(
            store: store,
            upload: upload,
            cleanup: cleanup,
            now: now
        )
    }
}

enum CoordinatorTestError: Error {
    case uploadFailed
}
