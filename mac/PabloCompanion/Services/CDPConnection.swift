import Foundation
import os
import Starscream

/// Minimal Chrome DevTools Protocol client over WebSocket using Starscream.
///
/// URLSessionWebSocketTask has known issues with Chrome's CDP implementation
/// (connection reset by peer). Starscream handles the WebSocket handshake
/// correctly and maintains a stable connection.
final class CDPConnection: WebSocketDelegate, @unchecked Sendable {
    private let wsURL: String
    private var socket: WebSocket?
    private var nextID = 1
    private var pendingCallbacks: [Int: CheckedContinuation<String, Error>] = [:]
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "CDPConnection")

    init(wsURL: String) {
        self.wsURL = wsURL
    }

    func connect() async throws {
        guard let url = URL(string: wsURL) else { throw EHRNavigatorError.browserNotFound }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let ws = WebSocket(request: request)
        ws.delegate = self
        self.socket = ws

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            connectContinuation = continuation
            lock.unlock()
            ws.connect()
        }

        // Verify with a test CDP call
        let result = try await evaluateJS("'cdp_ok'")
        guard result == "cdp_ok" else {
            throw EHRNavigatorError.browserNotFound
        }
        logger.info("CDP connected to \(self.wsURL)")
    }

    /// Evaluates JavaScript in the page and returns the string result.
    func evaluateJS(_ expression: String) async throws -> String {
        let reqID = nextRequestID()
        let command: [String: Any] = [
            "id": reqID,
            "method": "Runtime.evaluate",
            "params": ["expression": expression, "returnByValue": true],
        ]
        return try await sendCommand(command, id: reqID)
    }

    // MARK: - WebSocketDelegate

    func didReceive(event: WebSocketEvent, client _: any WebSocketClient) {
        switch event {
        case .connected:
            lock.lock()
            let continuation = connectContinuation
            connectContinuation = nil
            lock.unlock()
            continuation?.resume()

        case let .disconnected(reason, code):
            logger.info("CDP disconnected: \(reason) (\(code))")

        case let .text(text):
            handleMessage(Data(text.utf8))

        case let .binary(data):
            handleMessage(data)

        case let .error(error):
            logger.error("CDP error: \(error?.localizedDescription ?? "unknown")")
            lock.lock()
            let continuation = connectContinuation
            connectContinuation = nil
            lock.unlock()
            if let continuation {
                continuation.resume(
                    throwing: error ?? EHRNavigatorError.browserNotFound
                )
            }

        case .cancelled:
            logger.info("CDP cancelled")

        default:
            break
        }
    }

    // MARK: - Internal

    private func nextRequestID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let currentID = nextID
        nextID += 1
        return currentID
    }

    private func sendCommand(_ command: [String: Any], id: Int) async throws -> String {
        guard let ws = socket else { throw EHRNavigatorError.browserNotFound }
        let data = try JSONSerialization.data(withJSONObject: command)

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pendingCallbacks[id] = continuation
            lock.unlock()

            ws.write(data: data)
        }
    }

    private func handleMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? Int else { return }

        lock.lock()
        let continuation = pendingCallbacks.removeValue(forKey: id)
        lock.unlock()

        let resolved = extractCDPValue(from: json)
        switch resolved {
        case let .value(str):
            continuation?.resume(returning: str)
        case let .error(msg):
            continuation?.resume(
                throwing: EHRNavigatorError.actionFailed(action: "CDP", selector: msg)
            )
        case .empty:
            continuation?.resume(returning: "")
        }
    }

    private enum CDPResult {
        case value(String)
        case error(String)
        case empty
    }

    private func extractCDPValue(from json: [String: Any]) -> CDPResult {
        let resultDict = (json["result"] as? [String: Any])?["result"] as? [String: Any]
        if let value = resultDict?["value"] {
            if let strValue = value as? String { return .value(strValue) }
            if let boolValue = value as? Bool { return .value(boolValue ? "true" : "false") }
            return .value(String(describing: value))
        }
        let errorMsg = (json["error"] as? [String: Any])?["message"] as? String
        if let msg = errorMsg { return .error(msg) }
        return .empty
    }
}

// MARK: - String helper

extension String {
    var escapedForJS: String {
        self.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
