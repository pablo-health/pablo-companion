
@testable import CompanionSessionCore
import Foundation
import Testing

/// Round-trip coverage for the audio-upload pending queue. Mirrors the Windows
/// `PendingTranscriptionStoreTests`.
///
/// The encryption key comes from an in-memory provider, so these no longer touch
/// the real login Keychain. They previously did — prompting for access on every
/// run and leaving a key behind for each throwaway user.
@Suite("PendingAudioUploadStore round-trip")
struct PendingAudioUploadStoreTests {
    /// Unique per-test user so entries on disk don't collide across suites.
    /// A store rooted in its own temp directory.
    ///
    /// Every suite previously shared the real Application Support directory and
    /// relied on each test holding a different Keychain key so `loadAll` could
    /// not read its neighbours' entries — isolation by encryption accident. Now
    /// it is isolation by construction, and nothing touches a real disk.
    private static func makeStore(
        encryptor: SessionDataEncrypting? = FakeSessionDataEncryptor()
    ) -> PendingAudioUploadStore {
        var store = PendingAudioUploadStore(
            directory: Self.tempDir(),
            makeEncryptor: { _ in encryptor }
        )
        store.userEmail = "therapist@pablo.health"
        return store
    }

    private static func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-audio-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func addAndGetRoundTrip() throws {
        let store = Self.makeStore()
        store.add(
            sessionId: "session-A",
            micPath: "/tmp/mic.enc.pcm",
            systemPath: "/tmp/sys.enc.pcm",
            isEncrypted: true,
            sampleRate: 48000
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
        store.add(sessionId: "session-B", micPath: "/tmp/m.pcm", systemPath: nil, isEncrypted: false, sampleRate: 48000)
        store.remove(sessionId: "session-B")
        #expect(store.get(sessionId: "session-B") == nil)
    }

    @Test func incrementRetryPersists() throws {
        let store = Self.makeStore()
        store.add(sessionId: "session-C", micPath: "/tmp/m.pcm", systemPath: nil, isEncrypted: false, sampleRate: 48000)
        defer { store.remove(sessionId: "session-C") }

        store.incrementRetry(sessionId: "session-C")
        store.incrementRetry(sessionId: "session-C")

        let item = try #require(store.get(sessionId: "session-C"))
        #expect(item.retryCount == 2)
    }

    @Test func readdPreservesCreatedAtAndRetryCount() throws {
        let store = Self.makeStore()
        store.add(sessionId: "session-D", micPath: "/tmp/m.pcm", systemPath: nil, isEncrypted: false, sampleRate: 48000)
        defer { store.remove(sessionId: "session-D") }
        store.incrementRetry(sessionId: "session-D")
        let first = try #require(store.get(sessionId: "session-D"))

        // Re-adding the same session (e.g. orphan adoption finding it again on launch)
        // must not zero out retry state — it's the only thing keeping recovery
        // honest across launches.
        store.add(sessionId: "session-D", micPath: "/tmp/m.pcm", systemPath: nil, isEncrypted: false, sampleRate: 48000)
        let second = try #require(store.get(sessionId: "session-D"))

        #expect(second.retryCount == first.retryCount)
        #expect(second.createdAt == first.createdAt)
    }

    // MARK: - Capture rate

    @Test func nonDefaultSampleRateSurvivesRoundTrip() throws {
        // Bluetooth HFP drops the mic to 8/16/24 kHz. The rate has to persist
        // with the entry: a retry after relaunch has only headerless PCM to work
        // from, so if the queue forgets the rate the WAV gets stamped wrong and
        // transcription degrades — the bug #103 set out to fix.
        let store = Self.makeStore()
        store.add(
            sessionId: "session-E",
            micPath: "/tmp/m.pcm",
            systemPath: nil,
            isEncrypted: false,
            sampleRate: 24000
        )
        defer { store.remove(sessionId: "session-E") }

        let item = try #require(store.get(sessionId: "session-E"))
        #expect(item.sampleRate == 24000)
    }

    // MARK: - Key unavailable

    @Test func saveRefusesWhenKeyUnavailable() {
        // The branch that had no coverage before the seam existed. A store that
        // cannot encrypt must decline to write, not write something readable or
        // truncated. This is the same failure class as the Windows pending-store
        // cache poisoning, where a null key silently emptied the queue.
        let store = Self.makeStore(encryptor: nil)
        store.add(
            sessionId: "session-nokey",
            micPath: "/tmp/m.pcm",
            systemPath: nil,
            isEncrypted: false,
            sampleRate: 48000
        )
        defer { store.remove(sessionId: "session-nokey") }

        #expect(store.get(sessionId: "session-nokey") == nil)
    }

    @Test func loadAllIsEmptyWhenKeyUnavailable() {
        let store = Self.makeStore(encryptor: nil)
        #expect(store.loadAll().isEmpty)
    }

    @Test func aKeylessReadDoesNotDestroyExistingEntries() {
        // Losing the key must not be mistaken for "the queue is empty" — the
        // Windows bug cached that emptiness and later persisted it over real
        // data. Here a keyless read is transient: entries stay on disk and come
        // back when the encryptor does.
        let encryptor = FakeSessionDataEncryptor()
        let dir = Self.tempDir()
        var store = PendingAudioUploadStore(directory: dir, makeEncryptor: { _ in encryptor })
        store.userEmail = "therapist@pablo.health"
        store.add(
            sessionId: "session-F",
            micPath: "/tmp/m.pcm",
            systemPath: nil,
            isEncrypted: false,
            sampleRate: 48000
        )
        defer { store.remove(sessionId: "session-F") }

        var keyless = PendingAudioUploadStore(directory: dir, makeEncryptor: { _ in nil })
        keyless.userEmail = "therapist@pablo.health"
        #expect(keyless.loadAll().isEmpty)

        #expect(store.loadAll().count == 1)
    }

    @Test func theEncryptorIsResolvedForTheSignedInUser() {
        // The store must scope its key to whoever is signed in, not the
        // device-wide legacy key.
        let seen = Box<[String?]>([])
        var store = PendingAudioUploadStore(directory: Self.tempDir(), makeEncryptor: { email in
            seen.value.append(email)
            return FakeSessionDataEncryptor()
        })
        store.userEmail = "therapist@pablo.health"

        _ = store.loadAll()

        #expect(seen.value == ["therapist@pablo.health"])
    }

    // MARK: - Schema compatibility

    @Test func legacyEntryWithoutSampleRateStillDecodes() throws {
        // Entries queued before `sampleRate` existed are already on real disks.
        // Decoding must tolerate the missing key — a throw here would silently
        // drop a therapist's pending upload.
        let json = Data("""
        {
            "sessionId": "session-legacy",
            "micPath": "/tmp/m.pcm",
            "isEncrypted": false,
            "createdAt": 774144000,
            "retryCount": 2
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(
            PendingAudioUploadStore.PendingAudioUpload.self,
            from: json
        )

        #expect(decoded.sessionId == "session-legacy")
        #expect(decoded.retryCount == 2)
        #expect(decoded.sampleRate == nil)
    }
}
