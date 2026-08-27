@testable import CompanionSessionCore
import Foundation
import Testing

/// Covers the upload → note lifecycle: audio is kept until the note exists, not
/// deleted on the upload ack.
///
/// This is the fix for a real data-loss path. A backend race could accept the
/// upload and then fail to produce a note; deleting on the ack left the session
/// unrecoverable — audio gone, no note. Now a successful upload only moves the
/// entry to `awaitingNote`, and `reconcile()` deletes it only once the note is
/// confirmed.
@Suite("Upload → note lifecycle")
struct UploadLifecycleTests {

    private static func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lifecycle-\(UUID().uuidString)", isDirectory: true)
    }

    private static func makeStore() -> PendingAudioUploadStore {
        let encryptor = FakeSessionDataEncryptor()
        var store = PendingAudioUploadStore(directory: tempDir(), makeEncryptor: { _ in encryptor })
        store.userEmail = "therapist@pablo.health"
        return store
    }

    private static func queue(_ store: PendingAudioUploadStore, _ id: String) {
        store.add(
            sessionId: id,
            micPath: "/tmp/\(id)-mic.pcm",
            systemPath: nil,
            isEncrypted: false,
            sampleRate: 48000
        )
    }

    // MARK: - Upload does not delete when polling is configured

    @Test func aSuccessfulUploadKeepsTheAudioAndAwaitsTheNote() async throws {
        let store = Self.makeStore()
        Self.queue(store, "session-A")
        let cleaned = Box<[String]>([])
        let c = PendingAudioUploadCoordinator(
            store: store,
            upload: { _ in },
            cleanup: { cleaned.value.append($0.sessionId) },
            checkOutcome: { _ in .stillWorking }
        )

        _ = await c.drain()

        // Still queued, now awaiting the note — and NOT deleted.
        let entry = try #require(store.get(sessionId: "session-A"))
        #expect(entry.state == .awaitingNote)
        #expect(cleaned.value.isEmpty)
    }

    @Test func withoutPollingItStillDeletesOnUpload() async {
        // A caller that doesn't poll (checkOutcome nil) keeps the old behaviour.
        let store = Self.makeStore()
        Self.queue(store, "session-A")
        let cleaned = Box<[String]>([])
        let c = PendingAudioUploadCoordinator(
            store: store,
            upload: { _ in },
            cleanup: { cleaned.value.append($0.sessionId) }
        )

        _ = await c.drain()

        #expect(store.get(sessionId: "session-A") == nil)
        #expect(cleaned.value == ["session-A"])
    }

    // MARK: - reconcile acts on the backend's answer

    @Test func reconcileDeletesTheAudioOnceTheNoteExists() async {
        let store = Self.makeStore()
        Self.queue(store, "session-A")
        store.setState(sessionId: "session-A", .awaitingNote)
        let cleaned = Box<[String]>([])
        let c = PendingAudioUploadCoordinator(
            store: store,
            upload: { _ in },
            cleanup: { cleaned.value.append($0.sessionId) },
            checkOutcome: { _ in .noteReady }
        )

        let confirmed = await c.reconcile()

        #expect(confirmed == 1)
        #expect(store.get(sessionId: "session-A") == nil)
        #expect(cleaned.value == ["session-A"])
    }

    @Test func aBackendFailureReQueuesTheUploadAndKeepsTheAudio() async throws {
        // The data-loss scenario, now safe: the backend failed, so the audio
        // must survive and the upload must be retried — not deleted.
        let store = Self.makeStore()
        Self.queue(store, "session-A")
        store.setState(sessionId: "session-A", .awaitingNote)
        store.incrementRetry(sessionId: "session-A") // pretend it had retried
        let cleaned = Box<[String]>([])
        let c = PendingAudioUploadCoordinator(
            store: store,
            upload: { _ in },
            cleanup: { cleaned.value.append($0.sessionId) },
            checkOutcome: { _ in .failed }
        )

        _ = await c.reconcile()

        let entry = try #require(store.get(sessionId: "session-A"))
        #expect(entry.state == .pendingUpload) // back in the upload queue
        #expect(entry.retryCount == 0) // ladder reset — upload had succeeded
        #expect(cleaned.value.isEmpty) // audio NOT deleted
    }

    @Test func stillTranscribingLeavesTheEntryUntouched() async throws {
        let store = Self.makeStore()
        Self.queue(store, "session-A")
        store.setState(sessionId: "session-A", .awaitingNote)
        let cleaned = Box<[String]>([])
        let c = PendingAudioUploadCoordinator(
            store: store,
            upload: { _ in },
            cleanup: { cleaned.value.append($0.sessionId) },
            checkOutcome: { _ in .stillWorking }
        )

        let confirmed = await c.reconcile()

        #expect(confirmed == 0)
        let entry = try #require(store.get(sessionId: "session-A"))
        #expect(entry.state == .awaitingNote)
        #expect(cleaned.value.isEmpty)
    }

    @Test func anInconclusiveCheckNeverDeletes() async throws {
        // A network blip during the status check must not be read as "no note" —
        // that would delete the audio on a transient error.
        let store = Self.makeStore()
        Self.queue(store, "session-A")
        store.setState(sessionId: "session-A", .awaitingNote)
        let cleaned = Box<[String]>([])
        let c = PendingAudioUploadCoordinator(
            store: store,
            upload: { _ in },
            cleanup: { cleaned.value.append($0.sessionId) },
            checkOutcome: { _ in throw LifecycleTestError.checkFailed }
        )

        _ = await c.reconcile()

        let entry = try #require(store.get(sessionId: "session-A"))
        #expect(entry.state == .awaitingNote)
        #expect(cleaned.value.isEmpty)
    }

    // MARK: - drain and reconcile don't step on each other

    @Test func drainIgnoresAwaitingNoteEntries() async {
        // An awaiting-note entry must not be re-uploaded by the drain.
        let store = Self.makeStore()
        Self.queue(store, "session-A")
        store.setState(sessionId: "session-A", .awaitingNote)
        let uploaded = Box<[String]>([])
        let c = PendingAudioUploadCoordinator(
            store: store,
            upload: { uploaded.value.append($0.sessionId) },
            cleanup: { _ in },
            checkOutcome: { _ in .stillWorking }
        )

        _ = await c.drain()

        #expect(uploaded.value.isEmpty)
    }

    // MARK: - Persistence

    @Test func theAwaitingNoteStateSurvivesReload() throws {
        // A therapist can close the app mid-transcription; the state must be on
        // disk so the next launch resumes reconciliation rather than losing it.
        let dir = Self.tempDir()
        let encryptor = FakeSessionDataEncryptor()
        var store = PendingAudioUploadStore(directory: dir, makeEncryptor: { _ in encryptor })
        store.userEmail = "therapist@pablo.health"
        Self.queue(store, "session-A")
        store.setState(sessionId: "session-A", .awaitingNote)

        var reopened = PendingAudioUploadStore(directory: dir, makeEncryptor: { _ in encryptor })
        reopened.userEmail = "therapist@pablo.health"

        #expect(try #require(reopened.get(sessionId: "session-A")).state == .awaitingNote)
    }
}

enum LifecycleTestError: Error {
    case checkFailed
}
