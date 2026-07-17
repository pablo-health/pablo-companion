import Foundation
import Testing
@testable import CompanionSessionCore

/// Covers the session → recording map, including its plaintext → encrypted
/// migration.
///
/// The migration reads a legacy plaintext file, re-writes it encrypted, and then
/// **deletes the original**. It had no tests: it lived in the app target, where
/// running it meant launching the app. A migration that half-works loses the
/// linkage between a session and its recording — which is what the launch
/// recovery path uses to find audio that never uploaded.
@Suite("SessionRecordingStore")
struct SessionRecordingStoreTests {

    private static func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sessionrec-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeStore(
        directory: URL,
        encryptor: SessionDataEncrypting? = FakeSessionDataEncryptor()
    ) -> SessionRecordingStore {
        var store = SessionRecordingStore(directory: directory, makeEncryptor: { _ in encryptor })
        store.userEmail = "therapist@pablo.health"
        return store
    }

    private static func entry(_ id: UUID = UUID()) -> SessionRecordingStore.RecordingEntry {
        SessionRecordingStore.RecordingEntry(
            recordingID: id,
            fileURL: "/recordings/\(id)/session.wav",
            duration: 3000,
            createdAt: Date(timeIntervalSince1970: 774_144_000),
            isEncrypted: true,
            checksum: "abc123",
            channelLayout: "separatedStereo",
            micPCMFilePath: "/recordings/\(id)/mic.pcm",
            systemPCMFilePath: "/recordings/\(id)/system.pcm",
            sampleRate: 24000
        )
    }

    // MARK: - Round trip

    @Test func saveAndLoadRoundTrip() throws {
        let dir = Self.tempDir()
        let store = Self.makeStore(directory: dir)
        let e = Self.entry()

        store.save(sessionId: "session-A", entry: e)

        let loaded = try #require(store.loadAll()["session-A"])
        #expect(loaded.recordingID == e.recordingID)
        #expect(loaded.micPCMFilePath == e.micPCMFilePath)
        // The Bluetooth-HFP rate must survive: a retry after relaunch has only
        // headerless PCM to work from.
        #expect(loaded.sampleRate == 24000)
    }

    @Test func savingASecondSessionKeepsTheFirst() throws {
        let dir = Self.tempDir()
        let store = Self.makeStore(directory: dir)
        store.save(sessionId: "session-A", entry: Self.entry())
        store.save(sessionId: "session-B", entry: Self.entry())

        let all = store.loadAll()

        #expect(all.count == 2)
        #expect(all["session-A"] != nil)
        #expect(all["session-B"] != nil)
    }

    @Test func anEmptyStoreLoadsEmpty() {
        #expect(Self.makeStore(directory: Self.tempDir()).loadAll().isEmpty)
    }

    // MARK: - At rest

    @Test func theMapIsEncryptedAtRest() throws {
        // Session IDs correlate to patient records on the backend. A regression
        // writing plaintext round-trips perfectly and passes every other test.
        let dir = Self.tempDir()
        let store = Self.makeStore(directory: dir)
        store.save(sessionId: "session-secret", entry: Self.entry())

        let raw = try Data(contentsOf: dir.appendingPathComponent("SessionRecordings.enc"))
        let text = String(decoding: raw, as: UTF8.self)

        #expect(!text.contains("session-secret"))
        #expect(!text.contains("recordingID"))
    }

    @Test func writeRefusesWhenNoKeyIsAvailable() {
        let dir = Self.tempDir()
        let store = Self.makeStore(directory: dir, encryptor: nil)

        store.save(sessionId: "session-A", entry: Self.entry())

        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("SessionRecordings.enc").path))
    }

    // MARK: - Legacy migration

    @Test func aLegacyPlaintextStoreIsMigratedAndRemoved() throws {
        // The path that had no test. It rewrites the map encrypted and deletes
        // the plaintext original — a half-migration loses the session→recording
        // linkage the launch recovery path depends on.
        let dir = Self.tempDir()
        let legacy = dir.appendingPathComponent("SessionRecordings.json")
        let e = Self.entry()
        try JSONEncoder().encode(["session-legacy": e]).write(to: legacy)

        let store = Self.makeStore(directory: dir)
        let loaded = store.loadAll()

        #expect(loaded["session-legacy"]?.recordingID == e.recordingID)
        // Migrated to the encrypted file...
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("SessionRecordings.enc").path))
        // ...and the plaintext copy is gone, not left behind alongside it.
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test func migratedEntriesAreReadableOnTheNextLaunch() throws {
        // Migration must not be one-shot-and-lost: the second read comes from
        // the encrypted file, with the legacy one already deleted.
        let dir = Self.tempDir()
        let legacy = dir.appendingPathComponent("SessionRecordings.json")
        let e = Self.entry()
        try JSONEncoder().encode(["session-legacy": e]).write(to: legacy)

        let encryptor = FakeSessionDataEncryptor()
        let first = Self.makeStore(directory: dir, encryptor: encryptor)
        _ = first.loadAll()

        let second = Self.makeStore(directory: dir, encryptor: encryptor)
        #expect(second.loadAll()["session-legacy"]?.recordingID == e.recordingID)
    }

    @Test func theEncryptedStoreWinsOverAStaleLegacyFile() throws {
        // If both exist, the encrypted one is authoritative — otherwise a stale
        // plaintext file could resurrect old linkages over newer ones.
        let dir = Self.tempDir()
        let encryptor = FakeSessionDataEncryptor()
        let store = Self.makeStore(directory: dir, encryptor: encryptor)
        let current = Self.entry()
        store.save(sessionId: "session-current", entry: current)

        try JSONEncoder().encode(["session-stale": Self.entry()])
            .write(to: dir.appendingPathComponent("SessionRecordings.json"))

        let loaded = Self.makeStore(directory: dir, encryptor: encryptor).loadAll()

        #expect(loaded["session-current"] != nil)
        #expect(loaded["session-stale"] == nil)
    }

    @Test func anUnreadableLegacyFileDoesNotCrash() throws {
        let dir = Self.tempDir()
        try Data("this is not json".utf8).write(to: dir.appendingPathComponent("SessionRecordings.json"))

        #expect(Self.makeStore(directory: dir).loadAll().isEmpty)
    }

    @Test func aKeylessReadReturnsEmptyRatherThanDestroying() throws {
        // Losing the key must not read as "the map is empty" and then get
        // persisted over real data — the shape of the Windows cache-poisoning bug.
        let dir = Self.tempDir()
        let encryptor = FakeSessionDataEncryptor()
        let store = Self.makeStore(directory: dir, encryptor: encryptor)
        store.save(sessionId: "session-A", entry: Self.entry())

        #expect(Self.makeStore(directory: dir, encryptor: nil).loadAll().isEmpty)
        // The entry is still there once the key is back.
        #expect(Self.makeStore(directory: dir, encryptor: encryptor).loadAll().count == 1)
    }
}
