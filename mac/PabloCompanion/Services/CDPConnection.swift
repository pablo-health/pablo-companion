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
        guard let url = URL(string: wsURL) else { throw EHRNavigatorError.browserNotFound }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        self.webSocket = task
        task.resume()
        startReceiving()
        try await Task.sleep(for: .milliseconds(200))
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

        if let result = json["result"] as? [String: Any],
           let innerResult = result["result"] as? [String: Any],
           let value = innerResult["value"] {
            if let strValue = value as? String {
                continuation?.resume(returning: strValue)
            } else if let boolValue = value as? Bool {
                continuation?.resume(returning: boolValue ? "true" : "false")
            } else {
                continuation?.resume(returning: String(describing: value))
            }
        } else if let error = json["error"] as? [String: Any],
                  let errorMsg = error["message"] as? String {
            continuation?.resume(throwing: EHRNavigatorError.actionFailed(action: "CDP", selector: errorMsg))
        } else {
            continuation?.resume(returning: "")
        }
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
