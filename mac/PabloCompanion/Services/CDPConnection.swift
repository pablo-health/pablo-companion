import Foundation
import os

/// Minimal Chrome DevTools Protocol client over WebSocket.
/// Sends JSON commands and receives responses by matching request IDs.
final class CDPConnection: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let wsURL: String
    private var webSocket: URLSessionWebSocketTask?
    private var nextID = 1
    private var pendingCallbacks: [Int: CheckedContinuation<String, Error>] = [:]
    private let lock = NSLock()
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "CDPConnection")

    init(wsURL: String) {
        self.wsURL = wsURL
    }

    func connect() async throws {
        // Chrome CDP returns ws:// URLs — URLSessionWebSocketTask handles both ws:// and wss://
        guard let url = URL(string: wsURL) else { throw EHRNavigatorError.browserNotFound }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        self.webSocket = task
        task.resume()
        startReceiving()

        // Verify the connection is alive by sending a ping
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        logger.info("CDP WebSocket connected to \(self.wsURL)")
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

    // MARK: - Internal

    private func nextRequestID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let currentID = nextID
        nextID += 1
        return currentID
    }

    private func sendCommand(_ command: [String: Any], id: Int) async throws -> String {
        guard let socket = webSocket else { throw EHRNavigatorError.browserNotFound }
        let data = try JSONSerialization.data(withJSONObject: command)
        let message = URLSessionWebSocketTask.Message.data(data)

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pendingCallbacks[id] = continuation
            lock.unlock()

            socket.send(message) { [weak self] error in
                if let error {
                    self?.lock.lock()
                    let callback = self?.pendingCallbacks.removeValue(forKey: id)
                    self?.lock.unlock()
                    callback?.resume(throwing: error)
                }
            }
        }
    }

    private func startReceiving() {
        webSocket?.receive { [weak self] result in
            switch result {
            case let .success(message):
                self?.handleMessage(message)
                self?.startReceiving()
            case let .failure(error):
                self?.logger.error("CDP WebSocket error: \(error.localizedDescription)")
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case let .string(text):
            data = Data(text.utf8)
        case let .data(rawData):
            data = rawData
        @unknown default:
            return
        }

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
            continuation?.resume(throwing: EHRNavigatorError.actionFailed(action: "CDP", selector: msg))
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
