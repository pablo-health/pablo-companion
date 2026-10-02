import AudioCaptureKit
import CryptoKit
import Foundation

/// Runs the real capture graph for the first-use audio check, keeping nothing.
///
/// AudioCaptureKit always writes to a directory, so the check records into a
/// fresh temp folder, sealed with a key that exists only in memory, and the
/// folder is deleted when the check ends. Same capture path as a session —
/// which is the point of the check — without leaving audio behind.
@MainActor
final class AudioCheckCapture {
    /// Linear RMS levels, delivered on the main queue.
    var onLevels: ((_ mic: Float, _ system: Float) -> Void)?

    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pablo-audio-check-\(UUID().uuidString)", isDirectory: true)
    private let delegateAdapter = CaptureDelegateAdapter()
    private var session: CompositeCaptureSession?

    func start(micDeviceID: String?) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = CaptureConfiguration(
            sampleRate: 48000,
            bitDepth: 16,
            channels: 2,
            encryptor: ThrowawayEncryptor(),
            outputDirectory: directory,
            micDeviceID: micDeviceID,
            enableMicCapture: true,
            enableSystemCapture: true,
            mixingStrategy: .separated,
            exportRawPCM: false
        )
        let captureSession = CompositeCaptureSession(configuration: config)
        delegateAdapter.onLevelsUpdate = { [weak self] levels in
            Task { @MainActor in self?.onLevels?(levels.micLevel, levels.systemLevel) }
        }
        captureSession.delegate = delegateAdapter
        session = captureSession
        try captureSession.configure(config)
        try await captureSession.startCapture()
        delegateAdapter.startLevelsPolling()
    }

    /// Stops capture (if running) and deletes everything it wrote. Safe to call
    /// more than once, and after a failed start.
    func finish() async {
        delegateAdapter.stopLevelsPolling()
        if let session {
            _ = try? await session.stopCapture()
        }
        session = nil
        try? FileManager.default.removeItem(at: directory)
    }
}

/// AES-GCM with a random key that never leaves memory: whatever the check
/// writes is unreadable by the time the folder is deleted, and even if it
/// weren't deleted.
private struct ThrowawayEncryptor: CaptureEncryptor {
    private let key = SymmetricKey(size: .bits256)

    var algorithm: String {
        "AES-256-GCM"
    }

    func encrypt(_ data: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key).combined else {
            throw CaptureError.encryptionFailed("Failed to produce combined sealed box")
        }
        return combined
    }

    func keyMetadata() -> [String: String] {
        ["keyId": "audio-check-throwaway", "algorithm": algorithm]
    }
}
