import AudioCaptureKit
import CoreAudio
import Foundation

/// Returns the UID of the current default output audio device (e.g. speakers, AirPods).
func defaultOutputDeviceUID() -> String? {
    var deviceID: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address, 0, nil, &size, &deviceID
    )
    guard status == noErr else { return nil }

    address.mSelector = kAudioDevicePropertyDeviceUID
    var uid: Unmanaged<CFString>?
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let uidStatus = AudioObjectGetPropertyData(
        deviceID, &address, 0, nil, &size, &uid
    )
    guard uidStatus == noErr, let uid = uid?.takeUnretainedValue() else { return nil }
    return uid as String
}

/// Bridges the non-isolated AudioCaptureDelegate callbacks to MainActor closures.
///
/// Audio levels use a latest-value slot (NSLock-protected) so the audio callback
/// just writes and returns immediately — no dispatch, no Task creation.
/// A DispatchSourceTimer polls the slot at ~15fps and delivers batched updates on main.
/// State changes and errors are infrequent and dispatch to main via the existing
/// Task { @MainActor in } pattern set up by RecordingService.
final class CaptureDelegateAdapter: AudioCaptureDelegate, @unchecked Sendable {
    var onStateChange: (@Sendable (CaptureState) -> Void)?
    var onLevelsUpdate: (@Sendable (AudioLevels) -> Void)?
    var onError: (@Sendable (CaptureError) -> Void)?

    private let levelsLock = NSLock()
    private var latestLevels: AudioLevels?
    private var levelsTimer: DispatchSourceTimer?

    // MARK: - Levels Polling

    func startLevelsPolling() {
        stopLevelsPolling()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(66))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.levelsLock.lock()
            let levels = self.latestLevels
            self.latestLevels = nil
            self.levelsLock.unlock()
            if let levels {
                self.onLevelsUpdate?(levels)
            }
        }
        timer.resume()
        levelsTimer = timer
    }

    func stopLevelsPolling() {
        levelsTimer?.cancel()
        levelsTimer = nil
        levelsLock.lock()
        latestLevels = nil
        levelsLock.unlock()
    }

    // MARK: - AudioCaptureDelegate

    func captureSession(
        _: any AudioCaptureSession,
        didChangeState state: CaptureState
    ) {
        onStateChange?(state)
    }

    func captureSession(
        _: any AudioCaptureSession,
        didUpdateLevels levels: AudioLevels
    ) {
        // Atomic write — returns immediately, never blocks the audio thread.
        levelsLock.lock()
        latestLevels = levels
        levelsLock.unlock()
    }

    func captureSession(
        _: any AudioCaptureSession,
        didEncounterError error: CaptureError
    ) {
        onError?(error)
    }

    func captureSession(_: any AudioCaptureSession, didFinishCapture _: RecordingResult) {}
}

/// Sendable weak reference for safely passing across concurrency boundaries (e.g. CoreAudio callbacks).
final class WeakSendableBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) {
        self.value = value
    }
}
