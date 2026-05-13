import Foundation
import Testing
@testable import Pablo

/// Light round-trip coverage for the new audio-upload pending queue. Mirrors
/// the Windows `PendingTranscriptionStoreTests`. Hits the real macOS keychain
/// for the device encryption key (no test seam available, same constraint as
/// `PendingTranscriptStore`).
@Suite("PendingAudioUploadStore round-trip")
struct PendingAudioUploadStoreTests {
    /// Unique per-test user so entries don't collide with other suites or with
    /// real data already on the dev machine.
    private static func makeStore() -> PendingAudioUploadStore {
        var store = PendingAudioUploadStore()
        store.userEmail = "pending-audio-test+\(UUID().uuidString)@pablo.health"
        return store
    }

    @Test func addAndGetRoundTrip() throws {
        let store = Self.makeStore()
        store.add(
            sessionId: "session-A",
            micPath: "/tmp/mic.enc.pcm",
            systemPath: "/tmp/sys.enc.pcm",
            isEncrypted: true
        )
        defer { store.remove(sessionId: "session-A") }

        let item = try #require(store.get(sessionId: "session-A"))
        #expect(item.sessionId == "session-A")
        #expect(item.micPath == "/tmp/mic.enc.pcm")
        #expect(item.systemPath == "/tmp/sys.enc.pcm")
        #expect(item.isEncrypted == true)
        #expect(item.retryCount == 0)
    }

    @Test func removeDropsEntry() {
        let store = Self.makeStore()
        store.add(sessionId: "session-B", micPath: "/tmp/m.pcm", systemPath: nil, isEncrypted: false)
        store.remove(sessionId: "session-B")
        #expect(store.get(sessionId: "session-B") == nil)
    }

    @Test func incrementRetryPersists() throws {
        let store = Self.makeStore()
        store.add(sessionId: "session-C", micPath: "/tmp/m.pcm", systemPath: nil, isEncrypted: false)
        defer { store.remove(sessionId: "session-C") }

        store.incrementRetry(sessionId: "session-C")
        store.incrementRetry(sessionId: "session-C")

        let item = try #require(store.get(sessionId: "session-C"))
        #expect(item.retryCount == 2)
    }

    @Test func readdPreservesCreatedAtAndRetryCount() throws {
        let store = Self.makeStore()
        store.add(sessionId: "session-D", micPath: "/tmp/m.pcm", systemPath: nil, isEncrypted: false)
        defer { store.remove(sessionId: "session-D") }
        store.incrementRetry(sessionId: "session-D")
        let first = try #require(store.get(sessionId: "session-D"))

        // Re-adding the same session (e.g. orphan adoption finding it again on launch)
        // must not zero out retry state — it's the only thing keeping recovery
        // honest across launches.
        store.add(sessionId: "session-D", micPath: "/tmp/m.pcm", systemPath: nil, isEncrypted: false)
        let second = try #require(store.get(sessionId: "session-D"))

        #expect(second.retryCount == first.retryCount)
        #expect(second.createdAt == first.createdAt)
    }
}
