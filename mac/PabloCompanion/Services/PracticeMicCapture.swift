import AVFoundation
import Foundation
import os
import PracticeClientCore

/// Captures mic audio and delivers 16kHz 16-bit mono PCM frames for WebSocket streaming.
///
/// Runs independently of AudioCaptureKit — both can tap the mic simultaneously.
/// AudioCaptureKit handles the recording (for transcription), while this provides
/// the real-time stream for the Gemini Live API.
final class PracticeMicCapture: PracticeAudioSource, @unchecked Sendable {
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "PracticeMicCapture")
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var isCapturing = false

    /// Called with 20ms PCM chunks (640 bytes = 320 samples at 16kHz, 16-bit).
    var onAudioFrame: (@Sendable (Data) -> Void)?

    /// Current mic RMS level for visualization (0.0–1.0).
    var onLevelUpdate: (@Sendable (Float) -> Void)?

    /// Target format: 16kHz, 16-bit signed LE, mono
    private let targetFormat: AVAudioFormat = {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            preconditionFailure("16kHz mono PCM format must be supported")
        }
        return format
    }()

    /// 20ms at 16kHz = 320 samples
    private let frameSamples: AVAudioFrameCount = 320

    /// Accumulates samples until we have a full 20ms frame
    private var accumulator = Data()

    /// `PracticeAudioSource` conformance — captures from the default input device.
    func start() throws {
        try start(micDeviceID: nil)
    }

    func start(micDeviceID: String? = nil) throws {
        lock.lock()
        guard !isCapturing else {
            lock.unlock()
            return
        }
        lock.unlock()

        if let micDeviceID {
            setInputDevice(uid: micDeviceID)
        }

        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw PracticeMicError.noMicAvailable
        }

        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw PracticeMicError.converterFailed
        }

        let frameBytes = Int(frameSamples) * 2 // 16-bit = 2 bytes per sample

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { [weak self] buffer, _ in
            self?.processMicBuffer(buffer, converter: converter, frameBytes: frameBytes)
        }

        try engine.start()

        lock.lock()
        isCapturing = true
        lock.unlock()

        logger.info("Mic capture started (hardware: \(hardwareFormat.sampleRate)Hz → 16kHz)")
    }

    private func processMicBuffer(
        _ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, frameBytes: Int
    ) {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat, frameCapacity: outputFrameCount
        ) else { return }

        var convertError: NSError?
        converter.convert(to: outputBuffer, error: &convertError) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        guard convertError == nil, outputBuffer.frameLength > 0 else { return }

        let byteCount = Int(outputBuffer.frameLength) * 2
        guard let samples = outputBuffer.int16ChannelData?[0] else { return }
        let pcmData = Data(bytes: samples, count: byteCount)

        if let onLevelUpdate {
            let rms = computeRMS(samples, count: Int(outputBuffer.frameLength))
            onLevelUpdate(rms)
        }

        lock.lock()
        accumulator.append(pcmData)
        while accumulator.count >= frameBytes {
            let frame = accumulator.prefix(frameBytes)
            accumulator = Data(accumulator.dropFirst(frameBytes))
            lock.unlock()
            onAudioFrame?(frame)
            lock.lock()
        }
        lock.unlock()
    }

    func stop() {
        lock.lock()
        guard isCapturing else {
            lock.unlock()
            return
        }
        isCapturing = false
        lock.unlock()

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        accumulator = Data()
        logger.info("Mic capture stopped")
    }

    private func setInputDevice(uid: String) {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices

        guard let device = devices.first(where: { $0.uniqueID == uid }) else {
            logger.warning("Requested mic not found: \(uid)")
            return
        }

        // Set the input device on the audio engine's input node
        var deviceID = AudioDeviceID(device.uniqueID.hashValue)
        // Find the actual CoreAudio device ID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs)

        for id in deviceIDs {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidValue: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, &uidValue)
            guard status == noErr, let cfUID = uidValue?.takeUnretainedValue() else { continue }
            if (cfUID as String) == uid {
                deviceID = id
                break
            }
        }

        do {
            try engine.inputNode.auAudioUnit.setDeviceID(deviceID)
        } catch {
            logger.warning("Failed to set mic device: \(error.localizedDescription)")
        }
    }

    private func computeRMS(_ samples: UnsafePointer<Int16>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0 ..< count {
            let normalized = Float(samples[i]) / Float(Int16.max)
            sum += normalized * normalized
        }
        return sqrt(sum / Float(count))
    }
}

enum PracticeMicError: LocalizedError {
    case noMicAvailable
    case converterFailed

    var errorDescription: String? {
        switch self {
        case .noMicAvailable:
            "No microphone available. Check System Settings > Privacy & Security > Microphone."
        case .converterFailed:
            "Failed to initialize audio format converter."
        }
    }
}
