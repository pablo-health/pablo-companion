import AVFoundation
import Foundation
import os

/// Plays Pablo Bear's response audio through system speakers.
///
/// Receives PCM chunks (24kHz, 16-bit, mono) from the WebSocket client and queues
/// them for playback via AVAudioEngine. Playing through system audio output means
/// AudioCaptureKit will capture it as the "client" channel automatically.
final class PracticeAudioPlayer: @unchecked Sendable {
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "PracticeAudioPlayer")
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let outputFormat: AVAudioFormat
    private let lock = NSLock()
    private var isPlaying = false

    /// Current RMS level for waveform visualization (0.0–1.0).
    var onLevelUpdate: (@Sendable (Float) -> Void)?

    init() {
        // Pablo audio: 24kHz, 16-bit signed LE, mono
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24000,
            channels: 1,
            interleaved: true
        ) else {
            preconditionFailure("24kHz mono PCM format must be supported")
        }
        outputFormat = format
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: outputFormat)
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !isPlaying else { return }
        do {
            try engine.start()
            playerNode.play()
            isPlaying = true
            logger.info("Audio engine started")
        } catch {
            logger.error("Failed to start audio engine: \(error.localizedDescription)")
        }
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

    /// Queue a PCM chunk for immediate playback.
    func enqueue(_ pcmData: Data) {
        guard pcmData.count >= 2 else { return }

        let frameCount = AVAudioFrameCount(pcmData.count / 2) // 16-bit = 2 bytes per sample
        guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount) else {
            logger.warning("Failed to create audio buffer")
            return
        }
        buffer.frameLength = frameCount

        // Copy PCM data into the buffer
        pcmData.withUnsafeBytes { rawBuffer in
            guard let src = rawBuffer.baseAddress,
                  let dst = buffer.int16ChannelData?[0]
            else { return }
            memcpy(dst, src, pcmData.count)
        }

        // Compute RMS for waveform visualization
        if let onLevelUpdate {
            let rms = computeRMS(buffer)
            onLevelUpdate(rms)
        }

        playerNode.scheduleBuffer(buffer)
    }

    private func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.int16ChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }

        var sum: Float = 0
        for i in 0 ..< count {
            let normalized = Float(samples[i]) / Float(Int16.max)
            sum += normalized * normalized
        }
        return sqrt(sum / Float(count))
    }
}
