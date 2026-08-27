import Foundation

#if canImport(os)
import os
#endif

/// Monitors mic PCM file growth during recording and fires callbacks if data flow stalls.
///
/// - Finds the most recently created mic PCM file 10 seconds after recording starts
/// - Checks file size every 60 seconds
/// - Fires `onStalled` if size hasn't grown; fires `onResumed` when growth resumes
@MainActor
public final class RecordingWatchdog {
    public var onStalled: (() -> Void)?
    public var onResumed: (() -> Void)?

    private var timer: DispatchSourceTimer?
    private var micPCMPath: String?
    private var lastSize: UInt64 = 0
    private var hasBaseline = false
    private var stalledFired = false
    private let recordingsDirectory: URL
    #if canImport(os)
    private let logger: Logger
    #endif

    public init(recordingsDirectory: URL, logSubsystem: String = "health.pablo.companion") {
        self.recordingsDirectory = recordingsDirectory
        #if canImport(os)
        logger = Logger(subsystem: logSubsystem, category: "RecordingWatchdog")
        #endif
    }

    public func start() {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // First check at 10s (gives capture time to create files), then every 60s
        timer.schedule(deadline: .now() + .seconds(10), repeating: .seconds(60))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in self?.check() }
        }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        micPCMPath = nil
        lastSize = 0
        hasBaseline = false
        stalledFired = false
    }

    /// Internal rather than private so `RecordingWatchdogTests` can drive a tick
    /// directly — the timer starts at +10s and repeats every 60s, which no test
    /// can wait out. Mirrors the `Check()` seam on the Windows port.
    public func check() {
        if micPCMPath == nil {
            micPCMPath = findLatestMicPCMFile()?.path
        }
        guard let path = micPCMPath else {
            #if canImport(os)
            logger.warning("Could not find mic PCM file to monitor")
            #endif
            return
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let currentSize = attrs?[.size] as? UInt64 ?? 0
        defer {
            lastSize = currentSize
            hasBaseline = true
        }

        // First check — just baseline the size.
        //
        // The flag is explicit rather than `lastSize > 0`, which conflated "not
        // baselined yet" with "the file is empty" — so a mic file that was
        // created and never written stayed at 0, re-baselined on every tick, and
        // never reported a stall. That is the total-capture-failure case this
        // watchdog exists to catch. Matches the Windows port.
        guard hasBaseline else { return }

        if currentSize <= lastSize {
            if !stalledFired {
                stalledFired = true
                #if canImport(os)
                logger.warning("Mic PCM stalled at \(currentSize) bytes")
                #endif
                onStalled?()
            }
        } else if stalledFired {
            stalledFired = false
            #if canImport(os)
            logger.info("Mic PCM resumed growing (\(currentSize) bytes)")
            #endif
            onResumed?()
        }
    }

    private func findLatestMicPCMFile() -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let pcmFiles = contents.filter { $0.pathExtension == "pcm" }
        // Sort by creation date, newest first
        let sorted = pcmFiles.sorted { url1, url2 in
            let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return date1 > date2
        }
        // Prefer mic-specific file, fall back to any recent PCM
        return sorted.first { $0.lastPathComponent.localizedCaseInsensitiveContains("mic") }
            ?? sorted.first
    }
}
