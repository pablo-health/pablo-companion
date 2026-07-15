import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Test doubles

/// Decodes request-body bytes for substring assertions. Uses Latin-1 (never
/// fails, maps every byte 1:1) because the multipart body now carries binary
/// WAV headers — a UTF-8 decode would return nil on those bytes.
func bodyString(_ data: Data) -> String {
    String(data: data, encoding: .isoLatin1) ?? ""
}

/// Records that the binding closure ran (thread-safe).
final class BindingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func record(_: URLRequest) {
        lock.lock()
        calls += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

/// A captured request with its body materialized (URLProtocol delivers the body
/// via `httpBodyStream`, so it is drained once at intercept time).
struct CapturedRequest {
    let url: URL?
    let httpMethod: String?
    let capturedBody: Data
    private let headers: [String: String]
    func value(forHTTPHeaderField field: String) -> String? {
        headers[field]
    }

    init(_ request: URLRequest) {
        url = request.url
        httpMethod = request.httpMethod
        headers = request.allHTTPHeaderFields ?? [:]
        if let body = request.httpBody {
            capturedBody = body
        } else if let stream = request.httpBodyStream {
            capturedBody = Self.drain(stream)
        } else {
            capturedBody = Data()
        }
    }

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// A URLProtocol stub that returns queued responses in order and records every
/// request it intercepts. Install per test; the owning `.serialized` suite keeps
/// the shared static state race-free.
class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Canned {
        let status: Int
        let body: Data
    }

    private static let lock = NSLock()
    // Lock-protected shared state; `nonisolated(unsafe)` opts out of the Swift 6
    // global-actor check because `lock` provides the synchronization.
    nonisolated(unsafe) private static var responses: [Canned] = []
    nonisolated(unsafe) private static var index = 0
    nonisolated(unsafe) private static var recorder: StubURLProtocol.Recorder?

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _captured: [CapturedRequest] = []
        var captured: [CapturedRequest] {
            lock.lock()
            defer { lock.unlock() }
            return _captured
        }

        func add(_ request: URLRequest) {
            lock.lock()
            _captured.append(CapturedRequest(request))
            lock.unlock()
        }

        func enqueue(status: Int, json: String) {
            StubURLProtocol.lock.lock()
            StubURLProtocol.responses.append(Canned(status: status, body: Data(json.utf8)))
            StubURLProtocol.lock.unlock()
        }
    }

    static func install() -> Recorder {
        lock.lock()
        responses = []
        index = 0
        let recorder = Recorder()
        self.recorder = recorder
        lock.unlock()
        return recorder
    }

    static func reset() {
        lock.lock()
        responses = []
        index = 0
        recorder = nil
        lock.unlock()
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.recorder?.add(request)
        let canned = Self.index < Self.responses.count ? Self.responses[Self.index] : nil
        Self.index += 1
        Self.lock.unlock()

        guard let canned, let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: canned.status, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: canned.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
