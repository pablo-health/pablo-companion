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
        let dir = Self.makeDirectory()
        try? Data(repeating: 0x01, count: 999).write(to: dir.appendingPathComponent("recording_123_system.pcm"))
        Self.writeMicPCM(in: dir, bytes: 0)
        let watchdog = RecordingWatchdog(recordingsDirectory: dir)

        var stalled = false
        watchdog.onStalled = { stalled = true }

        // Monitoring the system file would see 999 bytes; the mic file is the
        // one that is dead, and it is the one that must be watched.
        watchdog.check()
        watchdog.check()

        #expect(stalled)
    }
}
