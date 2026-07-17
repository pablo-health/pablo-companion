import Foundation
import Testing
@testable import CompanionSessionCore

/// Covers deletion of local audio after a confirmed upload.
///
/// This is the PHI-retention path: recordings are encrypted at rest but kept
/// forever otherwise, and a session's sidecars run to hundreds of megabytes.
/// Once the backend has confirmed the bytes, the local copy has no reader.
@Suite("RecordingCleaner")
struct RecordingCleanerTests {

    private static func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleaner-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func write(_ name: String, in dir: URL) -> String {
        let url = dir.appendingPathComponent(name)
        try? Data(repeating: 0xAA, count: 512).write(to: url)
        return url.path
    }

    @Test func bothSidecarsAreDeleted() {
        let dir = Self.tempDir()
        let mic = Self.write("mic.pcm", in: dir)
        let system = Self.write("system.pcm", in: dir)

        RecordingCleaner.removeAudio(micPath: mic, systemPath: system)

        #expect(!FileManager.default.fileExists(atPath: mic))
        #expect(!FileManager.default.fileExists(atPath: system))
    }

    @Test func aMissingSystemSidecarIsFine() {
        // Mic-only sessions are normal — system audio is absent when the
        // therapist is in the room rather than on a call.
        let dir = Self.tempDir()
        let mic = Self.write("mic.pcm", in: dir)

        RecordingCleaner.removeAudio(micPath: mic, systemPath: nil)

        #expect(!FileManager.default.fileExists(atPath: mic))
    }

    @Test func deletingAnAlreadyDeletedFileIsNotAnError() {
        // Already gone is the desired end state, not a failure. A retry after a
        // partial delete must not be treated as a problem.
        let dir = Self.tempDir()
        let mic = Self.write("mic.pcm", in: dir)
        RecordingCleaner.removeAudio(micPath: mic, systemPath: nil)

        RecordingCleaner.removeAudio(micPath: mic, systemPath: nil)

        #expect(!FileManager.default.fileExists(atPath: mic))
    }

    @Test func aNonexistentPathDoesNotCrash() {
        RecordingCleaner.removeAudio(
            micPath: "/nonexistent/\(UUID().uuidString)/mic.pcm",
            systemPath: "/nonexistent/\(UUID().uuidString)/system.pcm"
        )
    }

    @Test func anUndeletableFileIsSwallowedRatherThanThrown() {
        // The bytes are already on the backend. A delete that fails costs disk;
        // letting it escape would fail an upload that actually succeeded.
        let dir = Self.tempDir()
        let mic = Self.write("mic.pcm", in: dir)
        // Make the parent immutable so the unlink fails.
        try? FileManager.default.setAttributes([.immutable: true], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }

        // Must not throw or trap.
        RecordingCleaner.removeAudio(micPath: mic, systemPath: nil)
    }

    @Test func onlyTheNamedFilesAreTouched() {
        // Cleanup is scoped to one session's sidecars. A neighbouring session's
        // audio must survive.
        let dir = Self.tempDir()
        let mic = Self.write("mic.pcm", in: dir)
        let other = Self.write("other-session-mic.pcm", in: dir)

        RecordingCleaner.removeAudio(micPath: mic, systemPath: nil)

        #expect(!FileManager.default.fileExists(atPath: mic))
        #expect(FileManager.default.fileExists(atPath: other))
    }
}
