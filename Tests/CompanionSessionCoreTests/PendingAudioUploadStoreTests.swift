
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
        // Asserted against the DIRECTORY, not against `get`. An earlier version
        // checked `get(...) == nil`, but `get` nil-guards on the same missing
        // encryptor before it ever reads disk — so it passed even if `save` had
        // written plaintext JSON. Only looking at the bytes distinguishes
        // "refused to write" from "wrote something unreadable".
        let dir = Self.tempDir()
        var store = PendingAudioUploadStore(directory: dir, makeEncryptor: { _ in nil })
        store.userEmail = "therapist@pablo.health"

        store.add(
            sessionId: "session-nokey",
            micPath: "/tmp/m.pcm",
            systemPath: nil,
            isEncrypted: false,
            sampleRate: 48000
        )

        let written = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(written.isEmpty)
    }

    @Test func entriesAreEncryptedAtRest() throws {
        // A regression that wrote plaintext JSON round-trips perfectly and passes
        // every other test in this suite. This is the only one that would catch
        // it — and these files are PHI-adjacent on a therapist's disk.
        let dir = Self.tempDir()
        var store = PendingAudioUploadStore(
            directory: dir,
            makeEncryptor: { _ in FakeSessionDataEncryptor() }
        )
        store.userEmail = "therapist@pablo.health"
        store.add(
            sessionId: "session-secret",
            micPath: "/recordings/session-secret/mic.pcm",
            systemPath: nil,
            isEncrypted: true,
            sampleRate: 48000
        )

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let name = try #require(files.first)
        let raw = try Data(contentsOf: dir.appendingPathComponent(name))
        let asText = String(decoding: raw, as: UTF8.self)

        #expect(!asText.contains("sessionId"))
        #expect(!asText.contains("session-secret"))
        #expect(!asText.contains("mic.pcm"))
    }

    @Test func aCorruptEntryDoesNotKillTheQueue() throws {
        // One unreadable file must not take the whole queue with it — the other
        // sessions are still uploadable.
        let encryptor = FakeSessionDataEncryptor()
        let dir = Self.tempDir()
        var store = PendingAudioUploadStore(directory: dir, makeEncryptor: { _ in encryptor })
        store.userEmail = "therapist@pablo.health"
        store.add(sessionId: "good", micPath: "/tmp/g.pcm", systemPath: nil, isEncrypted: false, sampleRate: 48000)

        try Data("not encrypted at all".utf8).write(to: dir.appendingPathComponent("garbage.enc"))

        let loaded = store.loadAll()

        #expect(loaded.count == 1)
        #expect(loaded.first?.sessionId == "good")
    }

    @Test func aSessionIDCannotEscapeTheStoreDirectory() {
        // sessionId reaches the filesystem. A traversal attempt must not write
        // outside the store.
        let dir = Self.tempDir()
        let encryptor = FakeSessionDataEncryptor()
        var store = PendingAudioUploadStore(directory: dir, makeEncryptor: { _ in encryptor })
        store.userEmail = "therapist@pablo.health"

        store.add(
            sessionId: "../escaped",
            micPath: "/tmp/m.pcm",
            systemPath: nil,
            isEncrypted: false,
            sampleRate: 48000
        )

        let parent = dir.deletingLastPathComponent()
        let escaped = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        #expect(!escaped.contains { $0.hasPrefix("escaped") })
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
