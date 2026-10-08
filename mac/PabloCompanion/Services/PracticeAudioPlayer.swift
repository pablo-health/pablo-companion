import AVFoundation
import Foundation
import os
import PracticeClientCore

/// Plays Pablo Bear's response audio through system speakers.
///
/// Receives PCM chunks (24kHz, 16-bit, mono) from the WebSocket client and queues
/// them for playback via AVAudioEngine. Playing through system audio output means
/// AudioCaptureKit will capture it as the "client" channel automatically.
final class PracticeAudioPlayer: PracticeAudioSink, @unchecked Sendable {
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "PracticeAudioPlayer")
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let outputFormat: AVAudioFormat?
    private let lock = NSLock()
    private var isPlaying = false
    private var isGraphConfigured = false

    /// Current RMS level for waveform visualization (0.0–1.0).
    var onLevelUpdate: (@Sendable (Float) -> Void)?

    /// The audio graph is NOT built here. `PracticeViewModel` (and so this
    /// player) is created at app launch, and `AVAudioEngine.connect` raises
    /// an Objective-C exception, which Swift cannot catch, when it rejects a
    /// format. Building the graph lazily in `start()` keeps a failure there
    /// from ever taking down app launch.
    init() {
        // The player node runs in the standard deinterleaved Float32 format.
        // macOS 15 rejects an Int16 player-node output format and aborts;
        // macOS 26 accepts it. Pablo's Int16 chunks are converted in `enqueue`.
        outputFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !isPlaying else { return }
        guard configureGraphIfNeeded() else { return }
        do {
            try engine.start()
            playerNode.play()
            isPlaying = true
            logger.info("Audio engine started")
        } catch {
            logger.error("Failed to start audio engine: \(error.localizedDescription)")
        }
    }

    /// Attaches and connects the player node once. Caller holds `lock`.
    private func configureGraphIfNeeded() -> Bool {
        if isGraphConfigured { return true }
        guard let outputFormat else {
            logger.error("24kHz mono Float32 format unavailable; practice audio disabled")
            return false
        }
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: outputFormat)
        isGraphConfigured = true
        return true
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isPlaying else { return }
        playerNode.stop()
        engine.stop()
        isPlaying = false
        logger.info("Audio engine stopped")
    }

    /// Queue a PCM chunk (24kHz, 16-bit signed LE, mono) for immediate playback.
    func enqueue(_ pcmData: Data) {
        let samples = Self.floatSamples(fromInt16LE: pcmData)
        guard !samples.isEmpty else { return }

        lock.lock()
        let ready = isPlaying
        lock.unlock()
        // Scheduling on a node that isn't attached to a running engine raises.
        guard ready, let outputFormat else { return }

        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount),
              let dst = buffer.floatChannelData?[0]
        else {
            logger.warning("Failed to create audio buffer")
            return
        }
        buffer.frameLength = frameCount
        samples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            dst.update(from: base, count: samples.count)
        }

        onLevelUpdate?(Self.rms(samples))
        playerNode.scheduleBuffer(buffer)
    }

    /// Converts 16-bit signed little-endian PCM to Float32 in [-1, 1].
    /// A trailing odd byte is ignored.
    static func floatSamples(fromInt16LE data: Data) -> [Float] {
        let count = data.count / 2
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            (0 ..< count).map { i in
                let value = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                return Float(value) / Float(Int16.max)
            }
        }
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sum / Float(samples.count))
    }
}
