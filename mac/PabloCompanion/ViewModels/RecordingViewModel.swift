import AudioCaptureKit
import AVFoundation
import CoreGraphics
import Foundation
import os

/// Manages recording UI state and delegates session lifecycle to RecordingService.
@MainActor
@Observable
final class RecordingViewModel {
    // MARK: - State

    var recordingState: RecordingUIState = .idle
    var micLevel: Float = 0
    var systemLevel: Float = 0
    var peakMicLevel: Float = 0
    var peakSystemLevel: Float = 0
    var duration: TimeInterval = 0
    var recordings: [LocalRecording] = []
    var availableMics: [AudioSource] = []
    var selectedMicID: String? {
        didSet { service.updateSelectedMic(selectedMicID) }
    }

    var encryptionEnabled = true
    var errorMessage: String?
    var showError = false
    var playingRecordingID: UUID?
    var onRecordingCompleted: ((LocalRecording) -> Void)?
    var activeSessionId: String?
    /// Maps session IDs to recording IDs for correlating sessions with local recordings.
    var sessionRecordingMap: [String: UUID] = [:]
    private let recordingStore = SessionRecordingStore()
    var systemAudioActive = false
    var bluetoothRoutingConflict = false
    var bluetoothRecommendation: String?
    var systemAudioPermitted: Bool = CGPreflightScreenCaptureAccess()

    // MARK: - Debug / Diagnostics

    var debugEnableMic = true
    var debugEnableSystem = true
    var debugDiagnostics: CaptureSessionDiagnostics = .init()

    // MARK: - Private

    let service = RecordingService()
    private var audioPlayer: AVAudioPlayer?
    private let playerDelegate = AudioPlayerDelegateAdapter()
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "RecordingViewModel")

    init() {
        configureServiceCallbacks()
    }

    // MARK: - Recording Controls

    func loadAudioSources() async {
        await service.loadAudioSources(currentMicID: selectedMicID)
    }

    func startRecording() async {
        await service.startRecording(
            encryptionEnabled: encryptionEnabled,
            debugEnableMic: debugEnableMic,
            debugEnableSystem: debugEnableSystem
        )
    }

    func pauseRecording() {
        service.pauseRecording()
    }

    func resumeRecording() {
        service.resumeRecording()
    }

    func stopRecording() async {
        await service.stopRecording()
        resetLevels()
    }

    // MARK: - Test Tone

    /// Generates a 3-second test tone recording (440Hz left, 880Hz right)
    /// that bypasses all capture. Proves the file writing + playback path works.
    func generateTestTone() {
        let sampleRate: Double = 48000
        let durationSecs = 3.0
        let pcmData = generateStereoPCM(sampleRate: sampleRate, duration: durationSecs)

        let header = AudioFormatConverter.generateWAVHeader(
            sampleRate: UInt32(sampleRate),
            bitDepth: 16,
            channels: 2,
            dataSize: UInt32(pcmData.count)
        )

        let fileName = "test_tone_\(UUID().uuidString).wav"
        let fileURL = service.recordingsDirectory.appendingPathComponent(fileName)
        do {
            var wavData = header
            wavData.append(pcmData)
            try wavData.write(to: fileURL)

            let recording = LocalRecording(
                id: UUID(),
                fileURL: fileURL,
                duration: durationSecs,
                createdAt: Date(),
                isEncrypted: false,
                checksum: "test-tone",
                channelLayout: .blended,
                micPCMFileURL: nil,
                systemPCMFileURL: nil,
                isUploaded: false
            )
            recordings.insert(recording, at: 0)
            logger.info("Test tone generated: \(fileName)")
        } catch {
            showErrorAlert("Failed to generate test tone: \(error.localizedDescription)")
        }
    }

    // MARK: - Playback

    func playRecording(_ recording: LocalRecording) {
        stopPlayback()

        do {
            let player: AVAudioPlayer
            if recording.isEncrypted {
                let wavData = try RecordingEncryptor.decryptFile(at: recording.fileURL)
                player = try AVAudioPlayer(data: wavData)
            } else {
                player = try AVAudioPlayer(contentsOf: recording.fileURL)
            }

            playerDelegate.onFinish = { [weak self] in
                Task { @MainActor in
                    self?.playingRecordingID = nil
                    self?.audioPlayer = nil
                }
            }
            player.delegate = playerDelegate
            player.play()
            audioPlayer = player
            playingRecordingID = recording.id
        } catch {
            logger.error("Playback failed: \(error.localizedDescription)")
            showErrorAlert("Playback failed: \(error.localizedDescription)")
        }
    }

    /// Returns the local recording associated with a session — checks in-memory first, then persisted store.
    func recordingForSession(_ sessionId: String) -> LocalRecording? {
        guard let recordingId = sessionRecordingMap[sessionId] else { return nil }
        if let inMemory = recordings.first(where: { $0.id == recordingId }) {
            return inMemory
        }
        // Fall back to reconstructing from persisted entry
        let persisted = recordingStore.loadAll()
        if let entry = persisted[sessionId] {
            return SessionRecordingStore.localRecording(from: entry)
        }
        return nil
    }

    /// Restore session→recording mappings from disk. Call on app launch.
    func restorePersistedRecordings() {
        let persisted = recordingStore.loadAll()
        for (sessionId, entry) in persisted {
            if sessionRecordingMap[sessionId] == nil {
                sessionRecordingMap[sessionId] = entry.recordingID
            }
            // Reconstruct LocalRecording if not already in memory
            let alreadyLoaded = recordings.contains { $0.id == entry.recordingID }
            if !alreadyLoaded, let recording = SessionRecordingStore.localRecording(from: entry) {
                recordings.append(recording)
            }
        }
        if !persisted.isEmpty {
            logger.info("Restored \(persisted.count) session→recording mappings from disk")
        }
    }

    /// Persist a session→recording mapping to disk.
    private func persistMapping(sessionId: String, recording: LocalRecording) {
        let entry = SessionRecordingStore.entry(from: recording)
        recordingStore.save(sessionId: sessionId, entry: entry)
    }

    /// Returns recordings on disk that are not linked to any session.
    func orphanedRecordings() -> [LocalRecording] {
        let linkedIDs = Set(sessionRecordingMap.values)
        return RecordingDirectoryScanner.scan(
            directory: service.recordingsDirectory,
            excluding: linkedIDs
        )
    }

    /// Link an orphaned recording to a session and persist the mapping.
    func linkRecording(_ recording: LocalRecording, toSession sessionId: String) {
        sessionRecordingMap[sessionId] = recording.id
        if !recordings.contains(where: { $0.id == recording.id }) {
            recordings.append(recording)
        }
        persistMapping(sessionId: sessionId, recording: recording)
        logger.info("Linked orphaned recording \(recording.id) to session \(sessionId)")
    }

    /// The session ID whose recording is currently playing, if any.
    var playingSessionId: String? {
        guard let playingRecordingID else { return nil }
        return sessionRecordingMap.first { $0.value == playingRecordingID }?.key
    }

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        playingRecordingID = nil
    }

    // MARK: - Service Callbacks

    private func configureServiceCallbacks() {
        configureRecordingCallbacks()
        configureDeviceCallbacks()
    }

    private func configureRecordingCallbacks() {
        service.onCaptureStateUpdate = { [weak self] state, elapsed in
            guard let self else { return }
            self.recordingState = state
            if let elapsed { self.duration = elapsed }
        }
        service.onDiagnosticsUpdate = { [weak self] diagnostics in
            self?.debugDiagnostics = diagnostics
        }
        service.onLevelsUpdate = { [weak self] levels in
            guard let self else { return }
            self.micLevel = levels.micLevel
            self.systemLevel = levels.systemLevel
            self.peakMicLevel = levels.peakMicLevel
            self.peakSystemLevel = levels.peakSystemLevel
        }
        service.onSystemAudioActiveChange = { [weak self] active in
            self?.systemAudioActive = active
        }
        service.onError = { [weak self] message in
            self?.showErrorAlert(message)
        }
        service.onRecordingCompleted = { [weak self] recording in
            self?.recordings.insert(recording, at: 0)
            if let sessionId = self?.activeSessionId {
                self?.sessionRecordingMap[sessionId] = recording.id
                self?.persistMapping(sessionId: sessionId, recording: recording)
            }
            self?.onRecordingCompleted?(recording)
        }
    }

    private func configureDeviceCallbacks() {
        service.onAvailableMicsUpdated = { [weak self] mics, selectedID in
            guard let self else { return }
            self.availableMics = mics
            self.selectedMicID = selectedID
        }
        service.onBluetoothConflict = { [weak self] conflict, recommendation in
            guard let self else { return }
            self.bluetoothRoutingConflict = conflict
            self.bluetoothRecommendation = recommendation
        }
        service.onSystemAudioPermittedChange = { [weak self] permitted in
            self?.systemAudioPermitted = permitted
        }
        service.onMicDisconnectedDuringRecording = { [weak self] in
            self?.showErrorAlert("Recording stopped: microphone was disconnected")
        }
        service.onDeviceChanged = { [weak self] in
            guard let self, self.playingRecordingID != nil else { return }
            self.logger.info("Device changed during playback, stopping playback")
            self.stopPlayback()
        }
    }

    // MARK: - Private Helpers

    private func resetLevels() {
        micLevel = 0
        systemLevel = 0
        peakMicLevel = 0
        peakSystemLevel = 0
        duration = 0
        systemAudioActive = false
    }

    private func showErrorAlert(_ message: String) {
        errorMessage = message
        showError = true
    }

    private func generateStereoPCM(sampleRate: Double, duration: Double) -> Data {
        let frameCount = Int(sampleRate * duration)
        var stereo = [Float](repeating: 0, count: frameCount * 2)
        for i in 0 ..< frameCount {
            let time = Float(i) / Float(sampleRate)
            stereo[i * 2] = 0.5 * sin(2.0 * .pi * 440.0 * time)
            stereo[i * 2 + 1] = 0.5 * sin(2.0 * .pi * 880.0 * time)
        }

        var pcmData = Data(capacity: stereo.count * 2)
        for sample in stereo {
            let clamped = max(-1.0, min(1.0, sample))
            var int16 = Int16(clamped * Float(Int16.max))
            withUnsafeBytes(of: &int16) { pcmData.append(contentsOf: $0) }
        }
        return pcmData
    }
}

// MARK: - UI State

enum RecordingUIState: Equatable, Sendable {
    case idle
    case recording
    case paused
}

// MARK: - CaptureError Helpers

extension CaptureError {
    var isSystemAudioConfigError: Bool {
        if case let .configurationFailed(msg) = self {
            return msg.contains("System audio")
        }
        return false
    }
}

// MARK: - Audio Player Delegate Adapter

private final class AudioPlayerDelegateAdapter: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    var onFinish: (@Sendable () -> Void)?

    func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
        onFinish?()
    }
}
