@testable import CompanionSessionCore
import Foundation
import Testing

/// A client who declines AI-assisted notes on the recording: the session's
/// audio is deleted, and nothing is left that could upload it — not the queue,
/// and not the session → recording map the launch-time sweep adopts from.
@Suite("Declined on the recording")
struct DeclinedRecordingTests {
    private static func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("declined-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func write(_ name: String, in dir: URL) -> String {
        let url = dir.appendingPathComponent(name)
        try? Data(repeating: 0xAA, count: 512).write(to: url)
        return url.path
    }

    private struct Fixture {
        let audioDir: URL
        let segments: [SessionAudioPaths]
        let recordingStore: SessionRecordingStore
        let uploadStore: PendingAudioUploadStore
    }

    /// Two segments (a mid-session device change), mapped and queued the way
    /// the app leaves a session it would otherwise upload.
    private static func recordedSession(_ sessionId: String) -> Fixture {
        let audioDir = tempDir()
        let segments = (1 ... 2).map { index in
            SessionAudioPaths(
                mixedPath: write("seg\(index).enc.wav", in: audioDir),
                micPath: write("seg\(index)_mic.enc.pcm", in: audioDir),
                systemPath: write("seg\(index)_system.enc.pcm", in: audioDir)
            )
        }
        // One key per store, as one signed-in user has: a fresh key per call
        // would read every entry back as nothing and pass vacuously.
        let encryptor = FakeSessionDataEncryptor()
        var recordingStore = SessionRecordingStore(
            directory: tempDir(),
            makeEncryptor: { _ in encryptor }
        )
        recordingStore.userEmail = "therapist@pablo.health"
        recordingStore.save(sessionId: sessionId, entry: SessionRecordingStore.RecordingEntry(
            recordingID: UUID(),
            fileURL: segments[1].mixedPath,
            duration: 60,
            createdAt: Date(),
            isEncrypted: true,
            checksum: "x",
            channelLayout: "separatedStereo",
            micPCMFilePath: segments[1].micPath,
            systemPCMFilePath: segments[1].systemPath,
            sampleRate: 48000
        ))
        var uploadStore = PendingAudioUploadStore(
            directory: tempDir(),
            makeEncryptor: { _ in encryptor }
        )
        uploadStore.userEmail = "therapist@pablo.health"
        uploadStore.add(
            sessionId: sessionId,
            micPath: segments[1].micPath ?? "",
            systemPath: segments[1].systemPath,
            mixedPath: segments[1].mixedPath,
            isEncrypted: true,
            sampleRate: 48000
        )
        return Fixture(audioDir: audioDir, segments: segments, recordingStore: recordingStore, uploadStore: uploadStore)
    }

    @Test func aDeclineLeavesNoAudioOnDisk() throws {
        let session = Self.recordedSession("session-D")

        RecordingCleaner.discardDeclined(
            sessionId: "session-D",
            audio: session.segments,
            recordingStore: session.recordingStore,
            uploadStore: session.uploadStore
        )

        let left = try FileManager.default.contentsOfDirectory(atPath: session.audioDir.path)
        #expect(left.isEmpty)
    }

    @Test func aDeclineUploadsNothing() async {
        let session = Self.recordedSession("session-D")
        // Seeded as the app leaves a session it would upload.
        #expect(session.uploadStore.get(sessionId: "session-D") != nil)
        #expect(session.recordingStore.loadAll()["session-D"] != nil)

        RecordingCleaner.discardDeclined(
            sessionId: "session-D",
            audio: session.segments,
            recordingStore: session.recordingStore,
            uploadStore: session.uploadStore
        )

        // Nothing queued, nothing the launch-time sweep could adopt.
        #expect(session.uploadStore.get(sessionId: "session-D") == nil)
        #expect(session.recordingStore.loadAll()["session-D"] == nil)

        // And the queue, drained as the app drains it, sends nothing.
        let attempted = Box<[String]>([])
        let coordinator = PendingAudioUploadCoordinator(
            store: session.uploadStore,
            upload: { attempted.value.append($0.sessionId) },
            cleanup: { _ in }
        )
        #expect(await coordinator.drain() == 0)
        #expect(await coordinator.forceDrain() == 0)
        #expect(attempted.value.isEmpty)
    }

    @Test func otherSessionsAreLeftAlone() {
        let session = Self.recordedSession("session-D")
        session.uploadStore.add(
            sessionId: "session-other", micPath: "/tmp/o.pcm", systemPath: nil, isEncrypted: false, sampleRate: 48000
        )

        RecordingCleaner.discardDeclined(
            sessionId: "session-D",
            audio: session.segments,
            recordingStore: session.recordingStore,
            uploadStore: session.uploadStore
        )

        #expect(session.uploadStore.get(sessionId: "session-other") != nil)
    }

    @Test func forgettingASessionKeepsTheRestOfTheMap() {
        let session = Self.recordedSession("session-D")
        let other = SessionRecordingStore.RecordingEntry(
            recordingID: UUID(), fileURL: "/tmp/other.wav", duration: 1, createdAt: Date(),
            isEncrypted: false, checksum: "y", channelLayout: "mono",
            micPCMFilePath: nil, systemPCMFilePath: nil, sampleRate: nil
        )
        session.recordingStore.save(sessionId: "session-other", entry: other)

        session.recordingStore.remove(sessionId: "session-D")

        #expect(Set(session.recordingStore.loadAll().keys) == ["session-other"])
    }
}
