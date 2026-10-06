import AudioCaptureKit
import Foundation

// MARK: - Encryption

/// Whether a capture can start, and with which encryptor.
enum CaptureEncryption {
    /// Start, sealing audio with this encryptor. Nil only in a debug build that
    /// asked to record in the clear.
    case ready(RecordingEncryptor?)
    /// Encryption is required and no key is available: don't start.
    case unavailable
}

extension RecordingService {
    /// Shown when a capture is refused because its audio can't be encrypted.
    static let encryptionUnavailableMessage =
        "Recording didn’t start because Pablo couldn’t encrypt the audio on this Mac."

    /// Whether a capture must be encrypted. Only a debug build may record in
    /// the clear; a release build encrypts whatever the caller asked for.
    static func encryptionRequired(requested: Bool) -> Bool {
        #if DEBUG
        return requested
        #else
        return true
        #endif
    }

    /// Resolves the encryptor for a new capture. Never `.ready(nil)` in a
    /// release build, so no release capture is configured without encryption.
    func captureEncryption(requested: Bool) -> CaptureEncryption {
        guard Self.encryptionRequired(requested: requested) else { return .ready(nil) }
        guard let encryptor = makeEncryptor(userEmail) else { return .unavailable }
        return .ready(encryptor)
    }

    /// The configuration for a session capture: 48 kHz stereo, mic and system
    /// audio kept on separate channels, with a raw PCM sidecar per channel.
    func captureConfiguration(
        encryptor: RecordingEncryptor?,
        micDeviceID: String?,
        enableMic: Bool,
        enableSystem: Bool
    ) -> CaptureConfiguration {
        CaptureConfiguration(
            sampleRate: 48000,
            bitDepth: 16,
            channels: 2,
            encryptor: encryptor,
            outputDirectory: recordingsDirectory,
            micDeviceID: micDeviceID,
            enableMicCapture: enableMic,
            enableSystemCapture: enableSystem,
            mixingStrategy: .separated,
            exportRawPCM: true
        )
    }
}

// MARK: - Rate Detection

extension RecordingService {
    /// Parses the actual output sample rate from the diagnostics mic format string.
    /// Format is "24000Hz 1ch non-int". Returns 48000 if parsing fails.
    static func parseOutputRate(from micFormat: String) -> Double {
        guard let hzRange = micFormat.range(of: "Hz") else { return 48000 }
        let rateString = micFormat[micFormat.startIndex ..< hzRange.lowerBound]
        guard let micRate = Double(rateString) else { return 48000 }
        return min(micRate, 48000)
    }
}

// MARK: - Recording Config

struct RecordingConfig {
    let encryptionEnabled: Bool
    let debugEnableMic: Bool
    let debugEnableSystem: Bool
}
