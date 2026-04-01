import Foundation
import Network
import os

/// Lightweight loopback HTTP server for OAuth redirect capture (RFC 8252 §7.3).
///
/// Binds to `127.0.0.1` on an OS-assigned ephemeral port. The authorization server
/// redirects the browser to `http://127.0.0.1:{port}/callback?code=...`, this server
/// captures the code, serves a branded "close this tab" page, and returns the callback URL.
///
/// Security: loopback traffic never leaves the machine. Combined with PKCE (already
/// implemented), the one-time auth code is useless even if intercepted.
final class LoopbackServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "health.pablo.loopback", qos: .userInitiated)
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "LoopbackServer")

    /// Guards single-resume of continuations. All access serialized via `queue`.
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var startContinuation: CheckedContinuation<UInt16, Error>?

    /// The OS-assigned port, available after `start()` returns.
    private(set) var port: UInt16 = 0

    /// The redirect URI to send to the authorization server.
    var redirectURI: String { "http://127.0.0.1:\(port)/callback" }

    enum ServerError: LocalizedError {
        case bindFailed
        case timeout
        case cancelled

        var errorDescription: String? {
            switch self {
            case .bindFailed: "Failed to start local auth server."
            case .timeout: "Sign-in timed out. Please try again."
            case .cancelled: "Sign-in was cancelled."
            }
        }
    }

    // MARK: - Lifecycle

    /// Binds to loopback on an ephemeral port. Returns the assigned port.
    /// Must be called before opening the browser (prevents port-hijack race).
    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: 0)

        let newListener = try NWListener(using: params)
        listener = newListener

        newListener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.queue.async {
                self.startContinuation = continuation
            }

            newListener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                self.queue.async {
                    guard let cont = self.startContinuation else { return }
                    switch state {
                    case .ready:
                        if let assignedPort = newListener.port?.rawValue {
                            self.startContinuation = nil
                            self.port = assignedPort
                            self.logger.info("Loopback server ready on port \(assignedPort)")
                            cont.resume(returning: assignedPort)
                        } else {
                            self.startContinuation = nil
                            cont.resume(throwing: ServerError.bindFailed)
                        }
                    case .failed:
                        self.startContinuation = nil
                        self.logger.error("Loopback server failed to start")
                        cont.resume(throwing: ServerError.bindFailed)
                    default:
                        break
                    }
                }
            }

            newListener.start(queue: self.queue)
        }
    }

    /// Waits for the browser to redirect to the callback URL.
    /// Returns the full callback URL including query parameters.
    func waitForCallback(timeout: TimeInterval = 120) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.callbackContinuation = continuation
            }

            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let cont = self.callbackContinuation else { return }
                self.callbackContinuation = nil
                self.logger.info("Loopback callback timed out after \(timeout)s")
                cont.resume(throwing: ServerError.timeout)
            }
        }
    }

    /// Stops the listener and cancels any pending callback.
    func stop() {
        listener?.cancel()
        listener = nil
        queue.sync {
            if let cont = callbackContinuation {
                callbackContinuation = nil
                cont.resume(throwing: ServerError.cancelled)
            }
            if let cont = startContinuation {
                startContinuation = nil
                cont.resume(throwing: ServerError.cancelled)
            }
        }
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self, let data,
                  let request = String(data: data, encoding: .utf8)
            else {
                connection.cancel()
                return
            }

            if let url = self.parseCallbackURL(from: request) {
                self.sendResponse(to: connection, html: Self.successHTML)
                self.queue.async {
                    guard let cont = self.callbackContinuation else { return }
                    self.callbackContinuation = nil
                    cont.resume(returning: url)
                }
            } else {
                self.sendResponse(to: connection, status: "404 Not Found", html: "")
            }
        }
    }

    private func parseCallbackURL(from httpRequest: String) -> URL? {
        guard let firstLine = httpRequest.split(separator: "\r\n").first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        let path = String(parts[1])
        guard path.hasPrefix("/callback") else { return nil }
        return URL(string: "http://127.0.0.1:\(port)\(path)")
    }

    private func sendResponse(to connection: NWConnection, status: String = "200 OK", html: String) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n"
        let responseData = Data((header + html).utf8)
        connection.send(content: responseData, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - HTML

    // swiftlint:disable line_length
    static let successHTML = """
    <!DOCTYPE html>
    <html><head><meta charset="utf-8"><title>Pablo</title>
    <style>body{font-family:-apple-system,'DM Sans',sans-serif;background:#FDF6EC;color:#2C1810;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}.card{text-align:center;padding:48px}h1{font-size:24px;margin-bottom:8px}p{color:#6B5B4F;font-size:16px}</style></head>
    <body><div class="card"><h1>Sign-in successful!</h1><p>You can close this tab and return to Pablo.</p></div>
    <script>setTimeout(function(){window.close()},2000)</script></body></html>
    """

    static let errorHTML = """
    <!DOCTYPE html>
    <html><head><meta charset="utf-8"><title>Pablo</title>
    <style>body{font-family:-apple-system,'DM Sans',sans-serif;background:#FDF6EC;color:#2C1810;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}.card{text-align:center;padding:48px}h1{font-size:24px;margin-bottom:8px;color:#C45B4A}p{color:#6B5B4F;font-size:16px}</style></head>
    <body><div class="card"><h1>Something went wrong</h1><p>Please try signing in again from the Pablo app.</p></div></body></html>
    """
    // swiftlint:enable line_length
}
