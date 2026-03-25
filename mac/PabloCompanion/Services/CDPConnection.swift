import Foundation
import Network
import os

/// Minimal WebSocket client for Chrome DevTools Protocol.
///
/// Uses Apple's Network framework (NWConnection) directly — no third-party
/// WebSocket library. Performs the HTTP upgrade handshake manually and logs
/// the full server response for diagnostics.
final class CDPConnection: @unchecked Sendable {
    private let wsURL: String
    private var connection: NWConnection?
    private var nextID = 1
    private var pendingCallbacks: [Int: CheckedContinuation<String, Error>] = [:]
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "CDPConnection")
    private let queue = DispatchQueue(label: "health.pablo.cdp", qos: .userInitiated)

    init(wsURL: String) {
        self.wsURL = wsURL
    }

    deinit {
        connection?.cancel()
    }

    // MARK: - Public

    func connect() async throws {
        guard let url = URL(string: wsURL),
              let host = url.host,
              let port = url.port
        else {
            throw EHRNavigatorError.browserNotFound
        }

        let conn = try await openTCPConnection(host: host, port: port)
        self.connection = conn

        try await performWebSocketUpgrade(
            conn: conn, host: host, port: port, path: url.path
        )

        readFrameHeader()

        let result = try await evaluateJS("'cdp_ok'")
        guard result == "cdp_ok" else {
            throw EHRNavigatorError.browserNotFound
        }
        logger.info("CDP connected to \(self.wsURL)")
    }

    private func openTCPConnection(host: String, port: Int) async throws -> NWConnection {
        let conn = NWConnection(
            host: .init(host),
            port: .init(integerLiteral: UInt16(port)),
            using: .tcp
        )
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.lock.lock()
            self.connectContinuation = cont
            self.lock.unlock()

            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.resumeConnect()
                case let .failed(error):
                    self.logger.error("CDP TCP failed: \(error)")
                    self.resumeConnect(throwing: error)
                case .cancelled:
                    self.resumeConnect(
                        throwing: EHRNavigatorError.browserNotFound
                    )
                default:
                    break
                }
            }
            conn.start(queue: self.queue)
        }
        return conn
    }

    private func resumeConnect(throwing error: Error? = nil) {
        lock.lock()
        let continuation = connectContinuation
        connectContinuation = nil
        lock.unlock()
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }

    private func performWebSocketUpgrade(
        conn: NWConnection, host: String, port: Int, path: String
    ) async throws {
        let wsPath = path.isEmpty ? "/" : path
        let key = Data((0 ..< 16).map { _ in UInt8.random(in: 0 ... 255) })
            .base64EncodedString()
        let request = [
            "GET \(wsPath) HTTP/1.1",
            "Host: \(host):\(port)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(key)",
            "Sec-WebSocket-Version: 13",
            "", "",
        ].joined(separator: "\r\n")

        try await sendRaw(Data(request.utf8))

        let response = try await readUntilHeaderEnd()
        logger.info("CDP upgrade response:\n\(response)")

        guard response.contains("101") else {
            logger.error("CDP: WebSocket upgrade rejected:\n\(response)")
            conn.cancel()
            throw EHRNavigatorError.actionFailed(
                action: "WebSocket upgrade",
                selector: String(response.prefix(200))
            )
        }
    }

    /// Sends an arbitrary CDP command (e.g. "Emulation.setUserAgentOverride").
    /// Ignores the result value — use for commands that return empty results.
    @discardableResult
    func sendCommand(method: String, params: [String: Any] = [:]) async throws -> String {
        let reqID = nextRequestID()
        let command: [String: Any] = [
            "id": reqID,
            "method": method,
            "params": params,
        ]
        let payload = try JSONSerialization.data(withJSONObject: command)
        let frame = Self.buildTextFrame(payload)

        guard let conn = connection else { throw EHRNavigatorError.browserNotFound }

        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            pendingCallbacks[reqID] = cont
            lock.unlock()

            conn.send(content: frame, completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                self?.lock.lock()
                let cb = self?.pendingCallbacks.removeValue(forKey: reqID)
                self?.lock.unlock()
                cb?.resume(throwing: error)
            })
        }
    }

    /// Evaluates JavaScript in the page and returns the string result.
    func evaluateJS(_ expression: String) async throws -> String {
        let reqID = nextRequestID()
        let command: [String: Any] = [
            "id": reqID,
            "method": "Runtime.evaluate",
            "params": ["expression": expression, "returnByValue": true],
        ]
        let payload = try JSONSerialization.data(withJSONObject: command)
        let frame = Self.buildTextFrame(payload)

        guard let conn = connection else { throw EHRNavigatorError.browserNotFound }

        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            pendingCallbacks[reqID] = cont
            lock.unlock()

            conn.send(content: frame, completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                self?.lock.lock()
                let cb = self?.pendingCallbacks.removeValue(forKey: reqID)
                self?.lock.unlock()
                cb?.resume(throwing: error)
            })
        }
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
    }

    // MARK: - WebSocket framing

    /// Builds a masked text WebSocket frame (client → server per RFC 6455).
    private static func buildTextFrame(_ payload: Data) -> Data {
        var frame = Data()
        frame.append(0x81) // FIN + text opcode

        let len = payload.count
        if len < 126 {
            frame.append(0x80 | UInt8(len))
        } else if len < 65536 {
            frame.append(0x80 | 126)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((len >> shift) & 0xFF))
            }
        }

        let mask: [UInt8] = (0 ..< 4).map { _ in UInt8.random(in: 0 ... 255) }
        frame.append(contentsOf: mask)
        for (i, byte) in payload.enumerated() {
            frame.append(byte ^ mask[i % 4])
        }
        return frame
    }

    // MARK: - Receive loop

    private func readFrameHeader() {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 2, maximumLength: 2) { [weak self] data, _, _, error in
            guard let self, let data, data.count == 2 else {
                if let error { self?.logger.error("CDP frame header: \(error)") }
                return
            }

            let opcode = data[0] & 0x0F
            let masked = (data[1] & 0x80) != 0
            let len7 = Int(data[1] & 0x7F)

            if opcode == 0x08 { // close
                self.logger.info("CDP: close frame received")
                return
            }

            if len7 < 126 {
                self.readPayload(conn: conn, length: len7, masked: masked, opcode: opcode)
            } else if len7 == 126 {
                self.readExtLength(conn: conn, bytes: 2, masked: masked, opcode: opcode)
            } else {
                self.readExtLength(conn: conn, bytes: 8, masked: masked, opcode: opcode)
            }
        }
    }

    private func readExtLength(conn: NWConnection, bytes: Int, masked: Bool, opcode: UInt8) {
        conn.receive(minimumIncompleteLength: bytes, maximumLength: bytes) { [weak self] data, _, _, error in
            guard let self, let data, data.count == bytes else {
                if let error { self?.logger.error("CDP ext length: \(error)") }
                return
            }
            var length = 0
            for byte in data {
                length = (length << 8) | Int(byte)
            }
            self.readPayload(conn: conn, length: length, masked: masked, opcode: opcode)
        }
    }

    private func readPayload(conn: NWConnection, length: Int, masked: Bool, opcode: UInt8) {
        guard length > 0 else {
            dispatch(opcode: opcode, payload: Data())
            readFrameHeader()
            return
        }

        conn.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self, let data else {
                if let error { self?.logger.error("CDP payload: \(error)") }
                return
            }

            var payload = data
            if masked {
                // Server frames shouldn't be masked per RFC, but handle anyway
                guard data.count >= 4 else { self.readFrameHeader()
                    return
                }
                let key = Array(data.prefix(4))
                payload = Data(data.dropFirst(4).enumerated().map {
                    $0.element ^ key[$0.offset % 4]
                })
            }

            self.dispatch(opcode: opcode, payload: payload)
            self.readFrameHeader()
        }
    }

    private func dispatch(opcode: UInt8, payload: Data) {
        switch opcode {
        case 0x09: // ping → pong (empty masked pong)
            connection?.send(
                content: Data([0x8A, 0x80, 0, 0, 0, 0]),
                completion: .idempotent
            )
        case 0x01, 0x00: // text or continuation
            handleCDPMessage(payload)
        default:
            break
        }
    }

    private func handleCDPMessage(_ data: Data) {
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

    // MARK: - Raw transport

    private func sendRaw(_ data: Data) async throws {
        guard let conn = connection else { throw EHRNavigatorError.browserNotFound }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    private func readUntilHeaderEnd() async throws -> String {
        guard let conn = connection else { throw EHRNavigatorError.browserNotFound }
        var buffer = Data()
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n

        while true {
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                    if let data {
                        cont.resume(returning: data)
                    } else {
                        cont.resume(throwing: error ?? EHRNavigatorError.browserNotFound)
                    }
                }
            }
            buffer.append(chunk)
            if buffer.contains(separator) {
                return String(data: buffer, encoding: .utf8) ?? "<binary response>"
            }
            if buffer.count > 8192 { break }
        }
        return String(data: buffer, encoding: .utf8) ?? "<oversized response>"
    }

    // MARK: - Helpers

    private func nextRequestID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        return id
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
