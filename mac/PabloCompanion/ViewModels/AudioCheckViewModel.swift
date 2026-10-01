import AppKit
import AudioCaptureKit
import AVFoundation
import Observation

/// Runs "Say hello to Pablo": Pablo greets the therapist through the speakers
/// (proving the system-audio path a client's voice takes), then the therapist
/// says hello (proving the mic). Under a minute, nothing kept.
@MainActor
@Observable
final class AudioCheckViewModel {
    enum Step: Equatable {
        case intro
        case greeting
        case yourTurn
        case done
    }

    /// Why capture couldn't start at all, if it couldn't.
    enum StartFailure: Equatable {
        case microphonePermission
        case systemAudioPermission
        case other(String)
    }

    static let greetingAssetName = "PabloGreeting"
    static let microphoneSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")

    private(set) var step: Step = .intro
    private(set) var heardComputer = false
    private(set) var heardYou = false
    private(set) var startFailure: StartFailure?

    var passed: Bool {
        heardComputer && heardYou && startFailure == nil
    }

    @ObservationIgnored private var evaluator = AudioCheckEvaluator()
    @ObservationIgnored private var capture: AudioCheckCapture?
    @ObservationIgnored private var player: AVAudioPlayer?

    private let greetingTimeout: TimeInterval = 10
    private let helloTimeout: TimeInterval = 8

    func run(micDeviceID: String?) async {
        reset()
        step = .greeting
        let capture = AudioCheckCapture()
        self.capture = capture
        capture.onLevels = { [weak self] mic, system in self?.ingest(mic: mic, system: system) }

        do {
            try await capture.start(micDeviceID: micDeviceID)
        } catch {
            startFailure = Self.failure(for: error)
            await finish()
            return
        }

        await playGreeting()
        step = .yourTurn
        await waitUntil(timeout: helloTimeout) { [weak self] in self?.heardYou ?? true }
        await finish()
    }

    /// Stop early (window closed, "Do it later"). Cleans up like a normal finish.
    func cancel() async {
        await finish()
    }

    // MARK: - Steps

    private func playGreeting() async {
        guard let asset = NSDataAsset(name: Self.greetingAssetName),
              let player = try? AVAudioPlayer(data: asset.data)
        else { return }
        self.player = player
        player.play()
        await waitUntil(timeout: greetingTimeout) { [weak self] in !(self?.player?.isPlaying ?? false) }
    }

    private func ingest(mic: Float, system: Float) {
        let phase: AudioCheckEvaluator.Phase
        switch step {
        case .greeting: phase = .greeting
        case .yourTurn: phase = .yourTurn
        case .intro, .done: return
        }
        evaluator.record(micRMS: mic, systemRMS: system, phase: phase, at: Date())
        if evaluator.heardComputer != heardComputer { heardComputer = evaluator.heardComputer }
        if evaluator.heardYou != heardYou { heardYou = evaluator.heardYou }
    }

    private func finish() async {
        player?.stop()
        player = nil
        await capture?.finish()
        capture = nil
        step = .done
    }

    private func reset() {
        evaluator = AudioCheckEvaluator()
        heardComputer = false
        heardYou = false
        startFailure = nil
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func failure(for error: Error) -> StartFailure {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
            return .microphonePermission
        }
        if case CaptureError.permissionDenied = error {
            return .systemAudioPermission
        }
        return .other(error.localizedDescription)
    }
}
