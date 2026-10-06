@testable import CompanionSessionCore
import Foundation
import Testing

/// A session whose capture restarts mid-way — the output device changed, so
/// the system-audio tap had to be rebuilt — is recorded in more than one
/// segment. Every segment is the session's audio.
///
/// The queue used to be keyed by session with the second segment overwriting
/// the first, and the live path uploaded only the last segment, so a restart
/// silently dropped everything recorded before it. These pin that every segment
/// reaches the upload, in order, and that none is deleted before the note
/// exists.
@Suite("Multi-segment session upload")
struct SegmentedUploadTests {
    // MARK: - Fixtures

    private static func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("segments-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeStore(
        directory: URL = tempDir(),
        encryptor: FakeSessionDataEncryptor = FakeSessionDataEncryptor()
    ) -> PendingAudioUploadStore {
        var store = PendingAudioUploadStore(directory: directory, makeEncryptor: { _ in encryptor })
        store.userEmail = "therapist@pablo.health"
        return store
    }

    /// Signed 16-bit LE PCM, one value per sample.
    private static func pcm(_ samples: [Int16]) -> Data {
        samples.map(\.littleEndian).withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func samples(_ data: Data) -> [Int16] {
        data.withUnsafeBytes { raw in
            (0 ..< raw.count / 2).map {
                Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))
            }
        }
    }

    /// Writes one segment's mixed file and sidecars; returns its paths.
    private static func writeSegment(
        in dir: URL,
        name: String,
        mic: [Int16],
        system: [Int16]?,
        sampleRate: Double = 48000
    ) throws -> AudioSegment {
        let micURL = dir.appendingPathComponent("\(name)_mic.pcm")
        let mixedURL = dir.appendingPathComponent("\(name).wav")
        try pcm(mic).write(to: micURL)
        try Data("RIFF-mixed".utf8).write(to: mixedURL)
        var systemPath: String?
        if let system {
            let url = dir.appendingPathComponent("\(name)_system.pcm")
            try pcm(system).write(to: url)
            systemPath = url.path
        }
        return AudioSegment(
            micPath: micURL.path,
            systemPath: systemPath,
            mixedPath: mixedURL.path,
            sampleRate: sampleRate
        )
    }

    private static func queue(_ segment: AudioSegment, session: String, in store: PendingAudioUploadStore) {
        store.add(
            sessionId: session,
            micPath: segment.micPath,
            systemPath: segment.systemPath,
            mixedPath: segment.mixedPath,
            isEncrypted: false,
            sampleRate: segment.sampleRate
        )
    }

    private static func plaintext(_ path: String) -> (url: URL, isTemp: Bool) {
        (URL(fileURLWithPath: path), false)
    }

    private static func exists(_ path: String?) -> Bool {
        path.map { FileManager.default.fileExists(atPath: $0) } ?? false
    }

    // MARK: - Queue

    @Test func aSecondSegmentIsAddedNotSubstituted() throws {
        let dir = Self.tempDir()
        let store = Self.makeStore()
        let first = try Self.writeSegment(in: dir, name: "a", mic: [1], system: [1, 1])
        let second = try Self.writeSegment(in: dir, name: "b", mic: [2], system: [2, 2])

        Self.queue(first, session: "s1", in: store)
        Self.queue(second, session: "s1", in: store)

        let entry = try #require(store.get(sessionId: "s1"))
        #expect(entry.segments == [first, second])
        #expect(store.loadAll().count == 1)
    }

    @Test func reAddingAQueuedSegmentKeepsOrderAndDetail() throws {
        let dir = Self.tempDir()
        let store = Self.makeStore()
        let first = try Self.writeSegment(in: dir, name: "a", mic: [1], system: nil)
        let second = try Self.writeSegment(in: dir, name: "b", mic: [2], system: nil)
        Self.queue(first, session: "s1", in: store)
        Self.queue(second, session: "s1", in: store)

        // The upload path re-adds without the mixed path; it must not be lost,
        // and neither segment may move or duplicate.
        store.add(sessionId: "s1", micPath: second.micPath, systemPath: nil, isEncrypted: false, sampleRate: 48000)
        store.add(sessionId: "s1", micPath: first.micPath, systemPath: nil, isEncrypted: false, sampleRate: 48000)

        let entry = try #require(store.get(sessionId: "s1"))
        #expect(entry.segments.map(\.micPath) == [first.micPath, second.micPath])
        #expect(entry.segments.map(\.mixedPath) == [first.mixedPath, second.mixedPath])
    }

    @Test func anEntryQueuedBeforeSegmentsExistedDecodesAsOneSegment() throws {
        let json = Data("""
        {"sessionId":"s1","micPath":"/a_mic.pcm","isEncrypted":false,"createdAt":0,"retryCount":0}
        """.utf8)
        let entry = try JSONDecoder().decode(PendingAudioUploadStore.PendingAudioUpload.self, from: json)
        #expect(entry.segments.map(\.micPath) == ["/a_mic.pcm"])
        #expect(entry.laterSegments.isEmpty)
    }

    @Test func relocationMovesEverySegment() throws {
        let store = Self.makeStore()
        let old = URL(fileURLWithPath: "/old")
        let new = URL(fileURLWithPath: "/new")
        store.add(sessionId: "s1", micPath: "/old/a_mic.pcm", systemPath: nil, isEncrypted: false, sampleRate: nil)
        store.add(
            sessionId: "s1", micPath: "/old/b_mic.pcm", systemPath: "/old/b_system.pcm",
            mixedPath: "/old/b.wav", isEncrypted: false, sampleRate: nil
        )

        store.relocateAudio(from: old, to: new)

        let entry = try #require(store.get(sessionId: "s1"))
        #expect(entry.segments.map(\.micPath) == ["/new/a_mic.pcm", "/new/b_mic.pcm"])
        #expect(entry.laterSegments.first?.systemPath == "/new/b_system.pcm")
        #expect(entry.laterSegments.first?.mixedPath == "/new/b.wav")
    }

    // MARK: - Staging

    @Test func oneSegmentUploadsItsOwnFilesUnchanged() throws {
        let dir = Self.tempDir()
        let only = try Self.writeSegment(in: dir, name: "a", mic: [1, 2], system: [3, 4], sampleRate: 16000)

        let staged = try SessionAudioStager.stage([only], fallbackRate: 48000, decrypt: Self.plaintext)

        #expect(staged.micURL.path == only.micPath)
        #expect(staged.systemURL?.path == only.systemPath)
        #expect(staged.sampleRate == 16000)
        #expect(staged.tempFiles.isEmpty)
    }

    @Test func twoSegmentsJoinIntoOneFilePerChannelInOrder() throws {
        let dir = Self.tempDir()
        let first = try Self.writeSegment(in: dir, name: "a", mic: [1, 2, 3], system: [10, 11, 12, 13, 14, 15])
        let second = try Self.writeSegment(in: dir, name: "b", mic: [4, 5], system: [16, 17, 18, 19])

        let staged = try SessionAudioStager.stage([first, second], fallbackRate: 48000, decrypt: Self.plaintext)
        defer { staged.tempFiles.forEach { try? FileManager.default.removeItem(at: $0) } }

        #expect(try Self.samples(Data(contentsOf: staged.micURL)) == [1, 2, 3, 4, 5])
        let system = try #require(staged.systemURL)
        #expect(try Self.samples(Data(contentsOf: system)) == [10, 11, 12, 13, 14, 15, 16, 17, 18, 19])
        #expect(staged.sampleRate == 48000)
    }

    @Test func aSegmentAtAnotherRateIsResampledToTheSessionRate() throws {
        let dir = Self.tempDir()
        // A Bluetooth headset in hands-free mode: 16 kHz, then back to 48 kHz.
        let headset = try Self.writeSegment(in: dir, name: "a", mic: [0, 300], system: nil, sampleRate: 16000)
        let builtIn = try Self.writeSegment(in: dir, name: "b", mic: [7, 7, 7], system: nil, sampleRate: 48000)

        let staged = try SessionAudioStager.stage([headset, builtIn], fallbackRate: 48000, decrypt: Self.plaintext)
        defer { staged.tempFiles.forEach { try? FileManager.default.removeItem(at: $0) } }

        #expect(staged.sampleRate == 48000)
        // Two frames at 16 kHz are six at 48 kHz, interpolated, then the
        // 48 kHz segment as it was.
        #expect(try Self.samples(Data(contentsOf: staged.micURL)) == [0, 100, 200, 300, 300, 300, 7, 7, 7])
    }

    @Test func aSegmentWithoutClientAudioKeepsTheChannelsAligned() throws {
        let dir = Self.tempDir()
        let first = try Self.writeSegment(in: dir, name: "a", mic: [1, 2], system: nil)
        let second = try Self.writeSegment(in: dir, name: "b", mic: [3], system: [9, 9])

        let staged = try SessionAudioStager.stage([first, second], fallbackRate: 48000, decrypt: Self.plaintext)
        defer { staged.tempFiles.forEach { try? FileManager.default.removeItem(at: $0) } }

        // Two mic frames of silence on the stereo client channel, then its audio.
        let system = try #require(staged.systemURL)
        #expect(try Self.samples(Data(contentsOf: system)) == [0, 0, 0, 0, 9, 9])
    }

    @Test func decryptedCopiesAreDeletedAfterJoining() throws {
        let dir = Self.tempDir()
        let first = try Self.writeSegment(in: dir, name: "a", mic: [1], system: [1, 1])
        let second = try Self.writeSegment(in: dir, name: "b", mic: [2], system: [2, 2])
        let made = Box<[URL]>([])
        let decrypt: SessionAudioStager.Decrypt = { path in
            let copy = dir.appendingPathComponent("plain-\(UUID().uuidString)")
            try FileManager.default.copyItem(atPath: path, toPath: copy.path)
            made.value.append(copy)
            return (copy, true)
        }

        let staged = try SessionAudioStager.stage([first, second], fallbackRate: 48000, decrypt: decrypt)
        defer { staged.tempFiles.forEach { try? FileManager.default.removeItem(at: $0) } }

        #expect(made.value.count == 4)
        #expect(made.value.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(try Self.samples(Data(contentsOf: staged.micURL)) == [1, 2])
    }

    @Test func aFailedStageLeavesNoPlaintextBehind() throws {
        let dir = Self.tempDir()
        let first = try Self.writeSegment(in: dir, name: "a", mic: [1], system: nil)
        let missing = AudioSegment(
            micPath: dir.appendingPathComponent("gone").path,
            systemPath: nil,
            mixedPath: nil,
            sampleRate: 48000
        )
        let work = Self.tempDir()

        #expect(throws: (any Error).self) {
            try SessionAudioStager.stage(
                [first, missing], fallbackRate: 48000, decrypt: Self.plaintext, workDirectory: work
            )
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty)
    }

    @Test func noSegmentsIsAnError() {
        #expect(throws: SessionUploadError.self) {
            try SessionAudioStager.stage([], fallbackRate: 48000, decrypt: Self.plaintext)
        }
    }

    // MARK: - Drain, upload, cleanup

    /// What the upload closure saw: the joined channels, read while they exist.
    private static func capturingUpload(
        into captured: Box<(mic: [Int16], system: [Int16])?>
    ) -> PendingAudioUploadCoordinator.UploadAttempt {
        { entry in
            let staged = try SessionAudioStager.stage(entry.segments, fallbackRate: 48000, decrypt: Self.plaintext)
            defer { staged.tempFiles.forEach { try? FileManager.default.removeItem(at: $0) } }
            let mic = try Self.samples(Data(contentsOf: staged.micURL))
            let system = try staged.systemURL.map { try Self.samples(Data(contentsOf: $0)) } ?? []
            captured.value = (mic, system)
        }
    }

    @Test func theUploadCarriesBothSegmentsAndNothingIsDeletedUntilTheNoteExists() async throws {
        let dir = Self.tempDir()
        let store = Self.makeStore()
        let first = try Self.writeSegment(in: dir, name: "a", mic: [1, 2], system: [5, 5, 6, 6])
        let second = try Self.writeSegment(in: dir, name: "b", mic: [3], system: [7, 7])
        Self.queue(first, session: "s1", in: store)
        Self.queue(second, session: "s1", in: store)

        let captured = Box<(mic: [Int16], system: [Int16])?>(nil)
        let outcome = Box(PendingAudioUploadCoordinator.SessionOutcome.stillWorking)
        let coordinator = PendingAudioUploadCoordinator(
            store: store,
            upload: Self.capturingUpload(into: captured),
            cleanup: { RecordingCleaner.removeAudio(of: $0.segments) },
            checkOutcome: { _ in outcome.value }
        )

        #expect(await coordinator.forceDrain(only: "s1") == 1)
        #expect(captured.value?.mic == [1, 2, 3])
        #expect(captured.value?.system == [5, 5, 6, 6, 7, 7])

        // Uploaded, note not ready: every file of every segment stays.
        let files = [first, second].flatMap { [$0.micPath, $0.systemPath, $0.mixedPath] }
        #expect(files.allSatisfy(Self.exists))
        #expect(await coordinator.reconcile() == 0)
        #expect(files.allSatisfy(Self.exists))

        outcome.value = .noteReady
        #expect(await coordinator.reconcile() == 1)
        #expect(!files.contains(where: Self.exists))
        #expect(store.get(sessionId: "s1") == nil)
    }

    @Test func aRelaunchedQueueStillUploadsEverySegment() async throws {
        let dir = Self.tempDir()
        let storeDir = Self.tempDir()
        let encryptor = FakeSessionDataEncryptor()
        let first = try Self.writeSegment(in: dir, name: "a", mic: [1], system: [4, 4])
        let second = try Self.writeSegment(in: dir, name: "b", mic: [2], system: [5, 5])

        // Launch-time adoption queues each recovered segment of the session, in
        // recording order, into the store on disk...
        let beforeQuit = Self.makeStore(directory: storeDir, encryptor: encryptor)
        Self.queue(first, session: "s1", in: beforeQuit)
        Self.queue(second, session: "s1", in: beforeQuit)

        // ...and the next launch's store, reading the same directory, drains it.
        let afterRelaunch = Self.makeStore(directory: storeDir, encryptor: encryptor)
        let captured = Box<(mic: [Int16], system: [Int16])?>(nil)
        let coordinator = PendingAudioUploadCoordinator(
            store: afterRelaunch,
            upload: Self.capturingUpload(into: captured),
            cleanup: { _ in },
            checkOutcome: { _ in .stillWorking }
        )

        #expect(await coordinator.drain() == 1)
        #expect(captured.value?.mic == [1, 2])
        #expect(captured.value?.system == [4, 4, 5, 5])
    }

    @Test func cleanupFindsAMixedFileQueuedWithoutItsPath() throws {
        let dir = Self.tempDir()
        let segment = try Self.writeSegment(in: dir, name: "recording_x", mic: [1], system: nil)
        let withoutMixed = AudioSegment(micPath: segment.micPath, systemPath: nil, mixedPath: nil, sampleRate: nil)

        RecordingCleaner.removeAudio(of: [withoutMixed])

        #expect(!Self.exists(segment.micPath))
        #expect(!Self.exists(segment.mixedPath))
    }
}
