import AVFoundation
import Foundation
import os

/// WebSocket client for practice mode audio streaming.
///
/// Sends therapist mic audio (PCM 16kHz mono) to the backend and receives
/// Pablo Bear's response audio (PCM 24kHz mono). Uses the hybrid text/binary
/// protocol defined in practice-mode-api.md.
final class PracticeWebSocketClient: @unchecked Sendable {
    // MARK: - Public state

    enum ConnectionState: Sendable {
        case disconnected
        case connecting
        case authenticating
        case waitingForSession
        case active
        case ending
    }

    enum PabloState: String, Sendable {
        case listening
        case processing
        case speaking
    }

    // MARK: - Callbacks (set by PracticeViewModel on MainActor)

    var onConnectionStateChanged: (@Sendable (ConnectionState) -> Void)?
    var onPabloStateChanged: (@Sendable (PabloState) -> Void)?
    var onAudioReceived: (@Sendable (Data, Bool) -> Void)?
    var onSessionStarted: (@Sendable (String) -> Void)?
    var onSessionEnded: (@Sendable (Int) -> Void)?
    var onError: (@Sendable (String, Bool) -> Void)?

    // MARK: - Private

    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "PracticeWebSocket")
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private let lock = NSLock()
    private var sendSequence: UInt16 = 0
    private var heartbeatTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?

    private var _state: ConnectionState = .disconnected
    var state: ConnectionState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    private func setState(_ newState: ConnectionState) {
        lock.lock()
        _state = newState
        lock.unlock()
        onConnectionStateChanged?(newState)
    }

    // MARK: - Connect

    func connect(url: URL) {
        disconnect()

        setState(.connecting)

        let session = URLSession(configuration: .default)
        urlSession = session

        let task = session.webSocketTask(with: url)
        webSocket = task
        task.resume()

        setState(.authenticating)
        startReceiving()
    }

    // MARK: - Session lifecycle

    func startSession(sessionId: String) {
        let message: [String: Any] = [
            "type": "session_start",
            "session_id": sessionId,
        ]
        sendJSON(message)
        setState(.waitingForSession)
    }

    func endSession() {
        sendJSON(["type": "session_end"])
        setState(.ending)
    }

    func pauseAudio() {
        sendJSON(["type": "audio_pause"])
    }

    func resumeAudio() {
        sendJSON(["type": "audio_resume"])
    }

    // MARK: - Send audio

    /// Sends a 20ms PCM audio frame with the 4-byte protocol header.
    func sendAudioFrame(_ pcmData: Data) {
        guard state == .active else { return }

        lock.lock()
        let seq = sendSequence
        sendSequence &+= 1
        lock.unlock()

        var frame = Data(capacity: 4 + pcmData.count)
        frame.append(0x01) // direction: client-to-server
        frame.append(0x00) // reserved
        frame.append(UInt8(seq >> 8)) // sequence high byte
        frame.append(UInt8(seq & 0xFF)) // sequence low byte
        frame.append(pcmData)

        webSocket?.send(.data(frame)) { [weak self] error in
            if let error {
                self?.logger.error("Failed to send audio frame: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Disconnect

    func disconnect() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        receiveTask?.cancel()
        receiveTask = nil

        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil

        lock.lock()
        sendSequence = 0
        lock.unlock()

        setState(.disconnected)
    }

    // MARK: - Receive loop

    private func startReceiving() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let ws = self.webSocket else { break }
                do {
                    let message = try await ws.receive()
                    self.handleMessage(message)
                } catch {
                    if !Task.isCancelled {
                        self.logger.error("WebSocket receive error: \(error.localizedDescription)")
                        self.onError?("Connection lost: \(error.localizedDescription)", true)
                        self.setState(.disconnected)
                    }
                    break
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case let .string(text):
            handleTextMessage(text)
        case let .data(data):
            handleBinaryMessage(data)
        @unknown default:
            logger.warning("Unknown WebSocket message type")
        }
    }

    // MARK: - Text message handling

    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else {
            logger.warning("Malformed text message")
            return
        }

        switch type {
        case "auth_result": handleAuthResult(json)
        case "session_started": handleSessionStarted(json)
        case "session_ended": handleSessionEnded(json)
        case "status": handleStatusUpdate(json)
        case "pong": break
        case "error": handleError(json)
        case "fatal_error": handleFatalError(json)
        default: logger.info("Unhandled message type: \(type)")
        }
    }

    private func handleAuthResult(_ json: [String: Any]) {
        if (json["status"] as? String) == "ok" {
            logger.info("Authenticated for practice session")
        } else {
            onError?("Authentication failed", true)
            disconnect()
        }
    }

    private func handleSessionStarted(_ json: [String: Any]) {
        setState(.active)
        sendSequence = 0
        startHeartbeat()
        if let sessionId = json["session_id"] as? String {
            onSessionStarted?(sessionId)
        }
        logger.info("Practice session started")
    }

    private func handleSessionEnded(_ json: [String: Any]) {
        let duration = json["duration_seconds"] as? Int ?? 0
        onSessionEnded?(duration)
        setState(.disconnected)
        logger.info("Practice session ended (\(duration)s)")
    }

    private func handleStatusUpdate(_ json: [String: Any]) {
        if let stateStr = json["state"] as? String,
           let pabloState = PabloState(rawValue: stateStr)
        {
            onPabloStateChanged?(pabloState)
        }
    }

    private func handleError(_ json: [String: Any]) {
        let msg = json["message"] as? String ?? "Unknown error"
        let recoverable = json["recoverable"] as? Bool ?? true
        logger.warning("Practice error: \(msg) (recoverable: \(recoverable))")
        onError?(msg, !recoverable)
    }

    private func handleFatalError(_ json: [String: Any]) {
        let msg = json["message"] as? String ?? "Fatal error"
        logger.error("Fatal practice error: \(msg)")
        onError?(msg, true)
        setState(.disconnected)
    }

    // MARK: - Binary message handling

    private func handleBinaryMessage(_ data: Data) {
        guard data.count >= 4 else {
            logger.warning("Binary frame too short (\(data.count) bytes)")
            return
        }

        // Parse 4-byte header
        let direction = data[0]
        guard direction == 0x02 else {
            logger.warning("Unexpected binary direction byte: \(direction)")
            return
        }

        let flags = data[1]
        let isFinal = (flags & 0x01) != 0
        let pcmData = data.subdata(in: 4 ..< data.count)

        onAudioReceived?(pcmData, isFinal)
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { break }
                let ts = Int(Date().timeIntervalSince1970 * 1000)
                self?.sendJSON(["type": "ping", "ts": ts])
            }
        }
    }

    // MARK: - JSON send helper

    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8)
        else { return }

        webSocket?.send(.string(text)) { [weak self] error in
            if let error {
                self?.logger.error("Failed to send JSON: \(error.localizedDescription)")
            }
        }
    }
}
