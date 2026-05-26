import Foundation

/// Produces upstream PCM frames for the practice WebSocket (16 kHz, s16le,
/// mono; 20 ms = 320 samples = 640 bytes per frame).
///
/// The macOS app's live-mic capture is one implementation; `FileAudioInputSource`
/// is a deterministic, hardware-free implementation that replays a fixture so
/// the client can be driven without a microphone.
public protocol PracticeAudioSource: AnyObject {
    var onAudioFrame: (@Sendable (Data) -> Void)? { get set }
    func start() throws
    func stop()
}

/// Consumes downstream patient-voice PCM (24 kHz, s16le, mono).
///
/// The macOS app plays this through the speakers; `CapturingAudioSink`
/// accumulates it in memory so a headless run can inspect what came back.
public protocol PracticeAudioSink: AnyObject {
    func start()
    func stop()
    func enqueue(_ pcmData: Data)
}

/// Replays a raw PCM fixture as 20 ms frames at wall-clock cadence, mirroring
/// how the live mic delivers chunks. Pacing matters: the server's VAD/turn
/// detection expects roughly real-time audio, not a burst.
public final class FileAudioInputSource: PracticeAudioSource, @unchecked Sendable {
    public var onAudioFrame: (@Sendable (Data) -> Void)?

    private let pcm: Data
    private let frameBytes: Int
    private let frameInterval: Duration
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - pcmURL: raw little-endian s16 PCM (no header), 16 kHz mono.
    ///   - frameBytes: bytes per frame (default 640 = 20 ms at 16 kHz s16le).
    ///   - frameIntervalMS: real-time gap between frames (default 20 ms).
    public init(pcmURL: URL, frameBytes: Int = 640, frameIntervalMS: Int = 20) throws {
        pcm = try Data(contentsOf: pcmURL)
        self.frameBytes = frameBytes
        frameInterval = .milliseconds(frameIntervalMS)
    }

    /// True once the whole fixture has been emitted.
    public private(set) var didFinish = false

    public func start() throws {
        let pcm = self.pcm
        let frameBytes = self.frameBytes
        let frameInterval = self.frameInterval
        lock.lock()
        task = Task { [weak self] in
            var offset = pcm.startIndex
            while offset < pcm.endIndex, !Task.isCancelled {
                let end = min(offset + frameBytes, pcm.endIndex)
                let frame = pcm.subdata(in: offset ..< end)
                self?.onAudioFrame?(frame)
                offset = end
                try? await Task.sleep(for: frameInterval)
            }
            self?.didFinish = true
        }
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        task?.cancel()
        task = nil
        lock.unlock()
    }
}

/// Accumulates downstream patient-voice PCM for post-run inspection
/// (length, RMS/VAD liveness, optional ASR round-trip).
public final class CapturingAudioSink: PracticeAudioSink, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var frameCount = 0

    public init() {}

    /// All captured PCM, in arrival order.
    public var captured: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    /// Number of downstream PCM chunks received.
    public var chunkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return frameCount
    }

    public func start() {}
    public func stop() {}

    public func enqueue(_ pcmData: Data) {
        lock.lock()
        buffer.append(pcmData)
        frameCount += 1
        lock.unlock()
    }

    /// Root-mean-square amplitude of the captured s16le PCM, normalised to
    /// 0...1. A near-zero value means silence (a red flag the audio path
    /// produced nothing intelligible).
    public func rms() -> Double {
        let data = captured
        guard data.count >= 2 else { return 0 }
        var sumSquares = 0.0
        var sampleCount = 0
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for sample in samples {
                let normalized = Double(Int16(littleEndian: sample)) / Double(Int16.max)
                sumSquares += normalized * normalized
                sampleCount += 1
            }
        }
        guard sampleCount > 0 else { return 0 }
        return (sumSquares / Double(sampleCount)).squareRoot()
    }
}
