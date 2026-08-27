import Foundation
import os
import PracticeClientCore

/// Orchestrates a practice session: topic selection → WebSocket connection →
/// mic capture → audio playback → session teardown.
@MainActor
@Observable
final class PracticeViewModel {
    // MARK: - State

    enum Phase: Equatable {
        case idle
        case loadingTopics
        case pickingTopic
        case connecting
        case active
        case ending
        case ended(durationSeconds: Int)
        case error(String)
    }

    var phase: Phase = .idle
    var topics: [PracticeTopic] = []
    var selectedTopic: PracticeTopic?
    var sessionId: String?
    var duration: TimeInterval = 0
    var micLevel: Float = 0
    var pabloLevel: Float = 0
    var pabloState: PracticeWebSocketClient.PabloState = .listening
    var errorMessage: String?
    var showError = false

    // MARK: - Dependencies

    var backendURL = AppConstants.defaultBackendAPIURL {
        didSet { apiClient.baseURL = backendURL }
    }

    private let apiClient = PracticeAPIClient()
    private let wsClient = PracticeWebSocketClient()
    private let micCapture = PracticeMicCapture()
    private let audioPlayer = PracticeAudioPlayer()
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "PracticeViewModel")
    private var durationTimer: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var sessionStartTime: Date?
    private var reconnectAttempts = 0
    private static let maxReconnectAttempts = 3

    /// The mic device UID to use (mirrors RecordingViewModel.selectedMicID).
    var selectedMicID: String?

    init() {
        // Preserve the app's real client-type header; the core defaults to a dev value.
        apiClient.clientType = "pablo-companion-macos/\(AppConstants.appVersion)"
        configureCallbacks()
    }

    // MARK: - Auth

    func configureAuth(
        getToken: @escaping @Sendable () async throws -> String,
        onAuthRejected: ((Bool) -> Void)? = nil
    ) {
        apiClient.getToken = getToken
        // The practice client has no error envelope; a 401 here is a plain
        // server-side session rejection (never a parsed idle-timeout code).
        apiClient.onUnauthorized = onAuthRejected.map { handler in { handler(false) } }
    }

    // MARK: - Topic loading

    func loadTopics() async {
        phase = .loadingTopics
        do {
            topics = try await apiClient.fetchTopics()
            phase = .pickingTopic
        } catch {
            logger.error("Failed to load topics: \(error.localizedDescription)")
            showErrorAlert("Failed to load practice topics: \(error.localizedDescription)")
            phase = .idle
        }
    }

    // MARK: - Session lifecycle

    func startSession(topic: PracticeTopic) async {
        selectedTopic = topic
        phase = .connecting

        do {
            // 1. Create session via REST
            let response = try await apiClient.createSession(topicId: topic.id)
            sessionId = response.sessionId
            logger.info("Practice session created: \(response.sessionId)")

            // 2. Connect WebSocket using the single-use ticket from session creation
            guard let wsURL = apiClient.webSocketURL(ticket: response.wsTicket) else {
                throw APIError.invalidResponse
            }
            wsClient.connect(url: wsURL)

            // 3. Start mic capture (will begin sending frames once WS is active)
            try micCapture.start(micDeviceID: selectedMicID)

            // 4. Start audio player (for Pablo's responses)
            audioPlayer.start()

            // 5. Wait briefly for auth, then send session_start
            try await Task.sleep(for: .milliseconds(500))
            wsClient.startSession(sessionId: response.sessionId)

        } catch {
            logger.error("Failed to start practice session: \(error.localizedDescription)")
            cleanup()
            showErrorAlert("Failed to start practice session: \(error.localizedDescription)")
            phase = .idle
        }
    }

    func endSession() {
        guard phase == .active else { return }
        phase = .ending
        wsClient.endSession()
    }

    func pauseAudio() {
        wsClient.pauseAudio()
    }

    func resumeAudio() {
        wsClient.resumeAudio()
    }

    func dismiss() {
        cleanup()
        phase = .idle
        selectedTopic = nil
        sessionId = nil
        duration = 0
    }

    /// Whether the practice session is currently in progress (active or ending).
    var isSessionActive: Bool {
        switch phase {
        case .active, .ending, .connecting:
            true
        default:
            false
        }
    }

    // MARK: - Callbacks

    private func configureCallbacks() {
        configureWebSocketCallbacks()
        configureAudioCallbacks()
    }

    private func configureWebSocketCallbacks() {
        wsClient.onConnectionStateChanged = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleConnectionState(state)
            }
        }

        wsClient.onPabloStateChanged = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.pabloState = state
            }
        }

        wsClient.onAudioReceived = { [weak self] pcmData, isFinal in
            self?.audioPlayer.enqueue(pcmData)
            if isFinal {
                Task { @MainActor [weak self] in
                    self?.pabloState = .listening
                }
            }
        }

        wsClient.onSessionStarted = { [weak self] sessionId in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sessionId = sessionId
                self.phase = .active
                self.sessionStartTime = Date()
                self.startDurationTimer()
                self.logger.info("Practice session active")
            }
        }

        wsClient.onSessionEnded = { [weak self] durationSeconds in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cleanup()
                self.phase = .ended(durationSeconds: durationSeconds)
                self.logger.info("Practice session ended (\(durationSeconds)s)")
            }
        }

        wsClient.onError = { [weak self] message, fatal in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if fatal {
                    self.cleanup()
                    self.phase = .error(message)
                }
                self.showErrorAlert(message)
            }
        }
    }

    private func configureAudioCallbacks() {
        micCapture.onAudioFrame = { [weak self] pcmData in
            self?.wsClient.sendAudioFrame(pcmData)
        }

        micCapture.onLevelUpdate = { [weak self] level in
            Task { @MainActor [weak self] in
                self?.micLevel = level
            }
        }

        audioPlayer.onLevelUpdate = { [weak self] level in
            Task { @MainActor [weak self] in
                self?.pabloLevel = level
            }
        }
    }

    private func handleConnectionState(_ state: PracticeWebSocketClient.ConnectionState) {
        switch state {
        case .disconnected:
            if case .active = phase {
                // Unexpected disconnect — attempt reconnection
                attemptReconnection()
            }
        case .connecting, .authenticating, .waitingForSession:
            break // already in .connecting phase
        case .active:
            reconnectAttempts = 0 // reset on successful connection
        case .ending:
            break // handled by onSessionEnded
        }
    }

    // MARK: - Reconnection

    /// Attempts to reconnect using a fresh single-use ticket.
    /// Retries up to 3 times within the server's 30-second reconnection window.
    private func attemptReconnection() {
        guard let sessionId, reconnectAttempts < Self.maxReconnectAttempts else {
            logger.error("Reconnection failed — max attempts reached")
            cleanup()
            phase = .error("Connection lost")
            return
        }

        reconnectAttempts += 1
        phase = .connecting
        logger.info("Reconnecting (attempt \(self.reconnectAttempts)/\(Self.maxReconnectAttempts))")

        let lastSeq = wsClient.lastReceivedSequence

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }

            // Brief backoff: 0.5s, 1s, 2s
            let delay = 0.5 * pow(2.0, Double(self.reconnectAttempts - 1))
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }

            do {
                let ticket = try await self.apiClient.fetchTicket()
                guard let wsURL = self.apiClient.webSocketURL(ticket: ticket) else {
                    throw APIError.invalidResponse
                }

                self.wsClient.disconnect(forReconnect: true)
                self.wsClient.connect(url: wsURL)

                // Wait for auth, then resume session
                try await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self.wsClient.resumeSession(sessionId: sessionId, lastSequence: lastSeq)

            } catch {
                guard !Task.isCancelled else { return }
                self.logger.error("Reconnect attempt failed: \(error.localizedDescription)")
                // Will trigger another handleConnectionState(.disconnected) → retry
                self.attemptReconnection()
            }
        }
    }

    // MARK: - Duration timer

    private func startDurationTimer() {
        durationTimer?.cancel()
        durationTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, let start = self.sessionStartTime else { break }
                self.duration = Date().timeIntervalSince(start)
            }
        }
    }

    // MARK: - Cleanup

    private func cleanup() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempts = 0
        durationTimer?.cancel()
        durationTimer = nil
        micCapture.stop()
        audioPlayer.stop()
        wsClient.disconnect()
        micLevel = 0
        pabloLevel = 0
        pabloState = .listening
    }

    // MARK: - Helpers

    private func showErrorAlert(_ message: String) {
        errorMessage = message
        showError = true
    }
}
