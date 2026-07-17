import Foundation
@testable import CompanionSessionCore
import Testing

/// Covers stall detection against real files on disk.
///
/// `check()` is driven directly: the timer fires first at +10s and then every
/// 60s, which no test can wait out.
@Suite("RecordingWatchdog stall detection")
@MainActor
struct RecordingWatchdogTests {

    private static func makeDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchdog-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func writeMicPCM(in dir: URL, bytes: Int) {
        let url = dir.appendingPathComponent("recording_123_mic.pcm")
        try? Data(repeating: 0xAA, count: bytes).write(to: url)
    }

    private static func growMicPCM(in dir: URL, toBytes: Int) {
        writeMicPCM(in: dir, bytes: toBytes)
    }

    // MARK: - The case the watchdog exists for

    @Test func aMicFileThatNeverGrowsFromZeroIsReportedStalled() {
        // The regression this guards: `lastSize > 0` conflated "not baselined"
        // with "file is empty", so a capture that produced a file and never
        // wrote a byte — total capture failure — re-baselined forever and never
        // reported a stall.
        let dir = Self.makeDirectory()
        Self.writeMicPCM(in: dir, bytes: 0)
        let watchdog = RecordingWatchdog(recordingsDirectory: dir)

        var stalled = false
        watchdog.onStalled = { stalled = true }

        watchdog.check() // baseline at 0 bytes
        watchdog.check() // still 0 — a dead capture

        #expect(stalled)
    }

    // MARK: - Normal operation

    @Test func aGrowingFileIsNotReportedStalled() {
        let dir = Self.makeDirectory()
        Self.writeMicPCM(in: dir, bytes: 1024)
        let watchdog = RecordingWatchdog(recordingsDirectory: dir)

        var stalled = false
        watchdog.onStalled = { stalled = true }

        watchdog.check()
        Self.growMicPCM(in: dir, toBytes: 4096)
        watchdog.check()

        #expect(!stalled)
    }

    @Test func theFirstCheckOnlyBaselinesAndNeverStalls() {
        let dir = Self.makeDirectory()
        Self.writeMicPCM(in: dir, bytes: 2048)
        let watchdog = RecordingWatchdog(recordingsDirectory: dir)

        var stalled = false
        watchdog.onStalled = { stalled = true }

        watchdog.check()

        #expect(!stalled)
    }

    @Test func aStalledFileReportsOnceNotEveryTick() {
        let dir = Self.makeDirectory()
        Self.writeMicPCM(in: dir, bytes: 512)
        let watchdog = RecordingWatchdog(recordingsDirectory: dir)

        var stallCount = 0
        watchdog.onStalled = { stallCount += 1 }

        watchdog.check()
        watchdog.check()
        watchdog.check()
        watchdog.check()

        #expect(stallCount == 1)
    }

    @Test func growthAfterAStallReportsResumed() {
        let dir = Self.makeDirectory()
        Self.writeMicPCM(in: dir, bytes: 512)
        let watchdog = RecordingWatchdog(recordingsDirectory: dir)

        var resumed = false
        watchdog.onResumed = { resumed = true }

        watchdog.check()
        watchdog.check() // stalls
        Self.growMicPCM(in: dir, toBytes: 8192)
        watchdog.check()

        #expect(resumed)
    }

    @Test func stopClearsBaselineSoTheNextRunReBaselines() {
        let dir = Self.makeDirectory()
        Self.writeMicPCM(in: dir, bytes: 512)
        let watchdog = RecordingWatchdog(recordingsDirectory: dir)

        var stalled = false
        watchdog.onStalled = { stalled = true }

        watchdog.check()
        watchdog.stop()
        // A fresh run must baseline again rather than compare against the old size.
        watchdog.check()

        #expect(!stalled)
    }

    // MARK: - Robustness

    @Test func aMissingDirectoryDoesNotCrashOrStall() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchdog-missing-\(UUID().uuidString)", isDirectory: true)
        let watchdog = RecordingWatchdog(recordingsDirectory: dir)

        var stalled = false
        watchdog.onStalled = { stalled = true }

        watchdog.check()
        watchdog.check()

        #expect(!stalled)
    }

    @Test func theMicFileIsPreferredOverOtherPCMFiles() {
        // The system file must GROW between checks. An earlier version of this
        // test left it static at 999 bytes, which meant watching the wrong file
        // also produced a stall — so it passed whether the selection worked or
        // not. Only a growing decoy makes the two outcomes distinguishable.
        let dir = Self.makeDirectory()
        let system = dir.appendingPathComponent("recording_123_system.pcm")
        try? Data(repeating: 0x01, count: 999).write(to: system)
        Self.writeMicPCM(in: dir, bytes: 0)
        let watchdog = RecordingWatchdog(recordingsDirectory: dir)

        var stalled = false
        watchdog.onStalled = { stalled = true }

        watchdog.check() // baseline
        try? Data(repeating: 0x01, count: 500_000).write(to: system) // system is alive
        watchdog.check() // mic is still 0 — dead

        // Watching the system file would see growth and report nothing.
        #expect(stalled)
    }

    @Test func aStaleSidecarFromAnEarlierSessionIsNotWatched() {
        // Sidecars from failed uploads are the norm on disk. Baselining against
        // an old session's dead file would report a stall for a capture that is
        // running perfectly.
        let dir = Self.makeDirectory()
        let stale = dir.appendingPathComponent("recording_000_mic.pcm")
        try? Data(repeating: 0x01, count: 4096).write(to: stale)
        // Make the stale file demonstrably older than the live one.
        try? FileManager.default.setAttributes(
            [.creationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: stale.path
        )
        let live = dir.appendingPathComponent("recording_999_mic.pcm")
        try? Data(repeating: 0x02, count: 1024).write(to: live)

        let watchdog = RecordingWatchdog(recordingsDirectory: dir)
        var stalled = false
        watchdog.onStalled = { stalled = true }

        watchdog.check()
        try? Data(repeating: 0x02, count: 200_000).write(to: live) // live one grows
        watchdog.check()

        #expect(!stalled)
    }

    @Test func aFileDeletedMidRecordingIsReportedStalled() {
        // attributesOfItem fails once the file is gone, which reads as size 0 —
        // that must count as a stall, not as a fresh baseline.
        let dir = Self.makeDirectory()
        Self.writeMicPCM(in: dir, bytes: 4096)
        let watchdog = RecordingWatchdog(recordingsDirectory: dir)

        var stalled = false
        watchdog.onStalled = { stalled = true }

        watchdog.check()
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("recording_123_mic.pcm"))
        watchdog.check()

        #expect(stalled)
    }
}
