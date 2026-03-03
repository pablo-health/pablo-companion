import AudioCaptureKit
import AVFoundation
import CoreAudio
import CoreGraphics
import Foundation
import os

/// Owns the AudioCaptureKit session and orchestrates the recording lifecycle.
/// Reports state changes back via closures registered by the caller (RecordingViewModel).
@MainActor
final class RecordingService {
    // MARK: - Callbacks

    /// Called when recording state or elapsed duration changes.
    /// Duration is `nil` on explicit control calls (pause/resume/stop start);
    /// it carries the actual elapsed seconds when delivered by the capture delegate.
    var onCaptureStateUpdate: ((RecordingUIState, TimeInterval?) -> Void)?
    var onDiagnosticsUpdate: ((CaptureSessionDiagnostics) -> Void)?
    var onLevelsUpdate: ((AudioLevels) -> Void)?
    var onSystemAudioActiveChange: ((Bool) -> Void)?
    var onError: ((String) -> Void)?
    var onRecordingCompleted: ((LocalRecording) -> Void)?
    var onAvailableMicsUpdated: (([AudioSource], String?) -> Void)?
    var onBluetoothConflict: ((Bool, String?) -> Void)?
    var onSystemAudioPermittedChange: ((Bool) -> Void)?
    var onMicDisconnectedDuringRecording: (() -> Void)?
    var onDeviceChanged: (() -> Void)?

    // MARK: - Internal

    var recordingsDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacOSSample-Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Private

    private var session: CompositeCaptureSession?
    private let delegateAdapter = CaptureDelegateAdapter()
    private var deviceChangeListenerInstalled = false
    private var systemAudioAvailableAtStart = false
    private var currentRecordingState: RecordingUIState = .idle
    private var selectedMicID: String?
    private var availableMics: [AudioSource] = []
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "RecordingService")

    // MARK: - Audio Sources

    func loadAudioSources(currentMicID: String?) async {
        onSystemAudioPermittedChange?(CGPreflightScreenCaptureAccess())
        await refreshAudioSources(currentMicID: currentMicID)
        installDeviceChangeListener()
    }

    func updateSelectedMic(_ micID: String?) {
        selectedMicID = micID
        checkBluetoothRoutingConflict()
    }

    func isMicStillAvailable(_ deviceUID: String) -> Bool {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return discoverySession.devices.contains { $0.uniqueID == deviceUID }
    }

    // MARK: - Recording Controls

    func startRecording(encryptionEnabled: Bool, debugEnableMic: Bool, debugEnableSystem: Bool) async {
        logger.info("Starting recording – system audio: \(self.systemAudioAvailableAtStart)")

        let encryptor: RecordingEncryptor? = encryptionEnabled ? RecordingEncryptor() : nil
        let config = CaptureConfiguration(
            sampleRate: 48000,
            bitDepth: 16,
            channels: 2,
            encryptor: encryptor,
            outputDirectory: recordingsDirectory,
            micDeviceID: selectedMicID,
            enableMicCapture: debugEnableMic,
            enableSystemCapture: debugEnableSystem
        )

        let captureSession = CompositeCaptureSession(configuration: config)
        self.session = captureSession
        configureDelegateCallbacks()
        captureSession.delegate = delegateAdapter

        do {
            try captureSession.configure(config)
            try await captureSession.startCapture()
            currentRecordingState = .recording
            onCaptureStateUpdate?(.recording, nil)
            onSystemAudioActiveChange?(systemAudioAvailableAtStart)
            logger.info("Recording started – systemAudioActive: \(self.systemAudioAvailableAtStart)")
        } catch {
            logger.error("Failed to start recording: \(error.localizedDescription)")
            onError?("Failed to start recording: \(error.localizedDescription)")
            currentRecordingState = .idle
            onCaptureStateUpdate?(.idle, nil)
            onSystemAudioActiveChange?(false)
        }
    }

    func pauseRecording() {
        guard let session else { return }
        do {
            try session.pauseCapture()
            currentRecordingState = .paused
            onCaptureStateUpdate?(.paused, nil)
            logger.info("Recording paused")
        } catch {
            logger.error("Failed to pause: \(error.localizedDescription)")
            onError?("Failed to pause: \(error.localizedDescription)")
        }
    }

    func resumeRecording() {
        guard let session else { return }
        do {
            try session.resumeCapture()
            currentRecordingState = .recording
            onCaptureStateUpdate?(.recording, nil)
            logger.info("Recording resumed")
        } catch {
            logger.error("Failed to resume: \(error.localizedDescription)")
            onError?("Failed to resume: \(error.localizedDescription)")
        }
    }

    func stopRecording() async {
        guard let session else { return }
        do {
            let result = try await session.stopCapture()
            logger.info("Recording stopped: \(result.fileURL.lastPathComponent)")

            let recording = LocalRecording(
                id: result.metadata.id,
                fileURL: result.fileURL,
                duration: result.duration,
                createdAt: Date(),
                isEncrypted: result.metadata.isEncrypted,
                checksum: result.checksum,
                isUploaded: false
            )
            onRecordingCompleted?(recording)
            currentRecordingState = .idle
            onCaptureStateUpdate?(.idle, nil)
        } catch {
            logger.error("Failed to stop recording: \(error.localizedDescription)")
            onError?("Failed to stop recording: \(error.localizedDescription)")
            currentRecordingState = .idle
            onCaptureStateUpdate?(.idle, nil)
        }
        onSystemAudioActiveChange?(false)
        self.session = nil
    }

    // MARK: - Private Helpers

    private func refreshAudioSources(currentMicID: String?) async {
        let tempSession = CompositeCaptureSession(
            configuration: CaptureConfiguration(outputDirectory: recordingsDirectory)
        )
        do {
            let sources = try await tempSession.availableAudioSources()
            availableMics = sources.filter { $0.type == .mic }
            let systemSources = sources.filter { $0.type == .system }
            systemAudioAvailableAtStart = !systemSources.isEmpty

            let currentMicStillAvailable = currentMicID
                .map { id in availableMics.contains(where: { $0.id == id }) } ?? false
            let newSelectedMicID = currentMicStillAvailable
                ? currentMicID
                : availableMics.first(where: { $0.isDefault })?.id ?? availableMics.first?.id
            selectedMicID = newSelectedMicID

            logger.info("Audio sources refreshed: \(self.availableMics.count) mic(s)")
            logger.info("System audio available: \(self.systemAudioAvailableAtStart)")
            onAvailableMicsUpdated?(availableMics, newSelectedMicID)
            checkBluetoothRoutingConflict()
        } catch {
            logger.error("Failed to load audio sources: \(error.localizedDescription)")
            onError?("Failed to load audio sources: \(error.localizedDescription)")
        }
    }

    private func installDeviceChangeListener() {
        guard !deviceChangeListenerInstalled else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let weakSelf = WeakSendableBox(self)
        let listenerBlock: @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void = { _, _ in
            DispatchQueue.main.async {
                Task { @MainActor in
                    guard let service = weakSelf.value else { return }
                    service.handleDeviceChange()
                    await service.refreshAudioSources(currentMicID: service.selectedMicID)
                }
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            nil,
            listenerBlock
        )

        if status == noErr {
            deviceChangeListenerInstalled = true
            logger.info("Audio device change listener installed")
        } else {
            logger.error("Failed to install audio device change listener: \(status)")
        }
    }

    private func handleDeviceChange() {
        logger.info("Audio device change detected, refreshing sources")

        if currentRecordingState == .recording || currentRecordingState == .paused {
            let micDisconnected = selectedMicID.map { !isMicStillAvailable($0) } ?? false
            if micDisconnected, let micID = selectedMicID {
                logger.warning("Selected mic \(micID) disconnected during recording, stopping")
                Task { await stopRecording() }
                onMicDisconnectedDuringRecording?()
            } else {
                logger.info("Device change during recording, but selected mic still available")
            }
        }

        onDeviceChanged?()
    }

    private func configureDelegateCallbacks() {
        delegateAdapter.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.handleCaptureState(state)
            }
        }
        delegateAdapter.onLevelsUpdate = { [weak self] levels in
            Task { @MainActor in
                self?.onLevelsUpdate?(levels)
            }
        }
        delegateAdapter.onError = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.logger.error("Capture error: \(error.localizedDescription)")
                if error.isSystemAudioConfigError {
                    self.onSystemAudioActiveChange?(false)
                    self.logger.warning("System audio not available, recording mic only")
                }
                self.onError?(error.localizedDescription)
            }
        }
    }

    private func handleCaptureState(_ state: CaptureState) {
        logger.debug("Capture state: \(String(describing: state))")
        switch state {
        case .idle:
            currentRecordingState = .idle
            onCaptureStateUpdate?(.idle, nil)
        case let .capturing(elapsed):
            currentRecordingState = .recording
            onCaptureStateUpdate?(.recording, elapsed)
            if let session {
                onDiagnosticsUpdate?(session.diagnostics)
            }
        case let .paused(elapsed):
            currentRecordingState = .paused
            onCaptureStateUpdate?(.paused, elapsed)
        case .stopping:
            currentRecordingState = .idle
            onCaptureStateUpdate?(.idle, nil)
            if let session {
                onDiagnosticsUpdate?(session.diagnostics)
            }
        case let .failed(error):
            currentRecordingState = .idle
            onCaptureStateUpdate?(.idle, nil)
            onSystemAudioActiveChange?(false)
            onError?(error.localizedDescription)
        default:
            break
        }
    }

    private func checkBluetoothRoutingConflict() {
        guard let selectedMicID,
              let mic = availableMics.first(where: { $0.id == selectedMicID }),
              mic.transportType == .bluetooth || mic.transportType == .bluetoothLE
        else {
            onBluetoothConflict?(false, nil)
            return
        }

        guard let outputUID = Self.defaultOutputDeviceUID() else {
            onBluetoothConflict?(false, nil)
            return
        }

        let micBase = selectedMicID.components(separatedBy: ":").first ?? selectedMicID
        let outputBase = outputUID.components(separatedBy: ":").first ?? outputUID

        if micBase == outputBase {
            let recommendation =
                "Using \(mic.name) as mic while it's also the audio output forces HFP mode (mono ~16 kHz). "
                    + "This is fine for speech recognition, but audio quality will drop. "
                    + "Switch to the built-in mic for higher quality, or continue if convenience matters more."
            onBluetoothConflict?(true, recommendation)
        } else {
            onBluetoothConflict?(false, nil)
        }
    }

    private static func defaultOutputDeviceUID() -> String? {
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
}

// MARK: - Delegate Adapter

/// Bridges the non-isolated AudioCaptureDelegate callbacks to MainActor closures.
private final class CaptureDelegateAdapter: AudioCaptureDelegate, @unchecked Sendable {
    var onStateChange: (@Sendable (CaptureState) -> Void)?
    var onLevelsUpdate: (@Sendable (AudioLevels) -> Void)?
    var onError: (@Sendable (CaptureError) -> Void)?

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
        onLevelsUpdate?(levels)
    }

    func captureSession(
        _: any AudioCaptureSession,
        didEncounterError error: CaptureError
    ) {
        onError?(error)
    }

    func captureSession(
        _: any AudioCaptureSession,
        didFinishCapture _: RecordingResult
    ) {}
}

// MARK: - Sendable Weak Reference

/// A Sendable wrapper for a weak reference to a MainActor-isolated object.
/// Used to safely pass a reference across concurrency boundaries (e.g. CoreAudio callbacks)
/// without triggering Swift 6 actor isolation traps.
private final class WeakSendableBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) {
        self.value = value
    }
}
