@testable import CompanionSessionCore
import Foundation
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Deterministic, network-free tests for the shared upload wire path. A stubbed
/// `URLProtocol` captures every request and returns canned responses, so the
/// bug-prone logic — the `INVALID_STATUS` self-heal, error-envelope parsing, and
/// the multipart body — is verified without touching a real backend (the e2e
/// harness covers the live happy path separately).
@Suite("AudioUploadClient", .serialized)
struct AudioUploadClientTests {

    // MARK: - Fixtures

    /// A short-lived temp directory with two raw-PCM sidecar files.
    private struct Fixtures {
        let dir: URL
        let mic: URL
        let system: URL

        init() throws {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("csc-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            mic = dir.appendingPathComponent("rec_mic.pcm")
            system = dir.appendingPathComponent("rec_system.pcm")
            try Data("mic-bytes".utf8).write(to: mic)
            try Data("system-bytes".utf8).write(to: system)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Builds a client whose URLSession is backed by the stub protocol.
    private func makeClient(bindingCalls: BindingRecorder? = nil) -> AudioUploadClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        return AudioUploadClient(
            baseURLString: "https://backend.test",
            token: { "test-bearer" },
            attachBinding: { request in
                request.setValue("proof-abc", forHTTPHeaderField: "DPoP")
                request.setValue("install-1", forHTTPHeaderField: "X-Install-ID")
                bindingCalls?.record(request)
            },
            session: session
        )
    }

    // MARK: - uploadAudio

    @Test("Successful upload decodes the response and sends a correct multipart body")
    func uploadSuccess() async throws {
        let fx = try Fixtures()
        defer { fx.cleanup() }
        let recorder = StubURLProtocol.install()
        defer { StubURLProtocol.reset() }
        recorder.enqueue(
            status: 200,
            json: #"{"id":"sess-1","status":"transcribing","queue":"default","message":"ok"}"#
        )

        let response = try await makeClient().uploadAudio(
            sessionId: "sess-1",
            therapistAudioURL: fx.mic,
            clientAudioURL: fx.system,
            onProgress: { _ in }
        )

        #expect(response.id == "sess-1")
        #expect(response.status == "transcribing")
        #expect(response.queue == "default")

        let sent = try #require(recorder.captured.first)
        #expect(sent.url?.absoluteString == "https://backend.test/api/sessions/sess-1/upload-audio")
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer test-bearer")
        #expect(sent.value(forHTTPHeaderField: "X-Client-Type") == "pablo-companion-macos/1.0")
        // Device binding was attached.
        #expect(sent.value(forHTTPHeaderField: "DPoP") == "proof-abc")
        #expect(sent.value(forHTTPHeaderField: "X-Install-ID") == "install-1")

        let body = bodyString(sent.capturedBody)
        #expect(body.contains("name=\"therapist_audio\""))
        #expect(body.contains("name=\"client_audio\""))
        #expect(body.contains("Content-Type: audio/wav"))
        #expect(body.contains("mic-bytes"))
        #expect(body.contains("system-bytes"))
        #expect(body.contains("filename=\"rec_mic.wav\""))
    }

    @Test("Missing optional client audio still uploads the therapist part")
    func uploadWithoutClientAudio() async throws {
        let fx = try Fixtures()
        defer { fx.cleanup() }
        let recorder = StubURLProtocol.install()
        defer { StubURLProtocol.reset() }
        recorder.enqueue(status: 200, json: #"{"id":"s","status":"transcribing","queue":null,"message":null}"#)

        _ = try await makeClient().uploadAudio(
            sessionId: "s", therapistAudioURL: fx.mic, clientAudioURL: nil, onProgress: { _ in }
        )
        let body = try bodyString(#require(recorder.captured.first).capturedBody)
        #expect(body.contains("name=\"therapist_audio\""))
        #expect(!body.contains("name=\"client_audio\""))
    }

    @Test("A non-2xx response throws SessionUploadError with the parsed backend code")
    func uploadMapsErrorEnvelope() async throws {
        let fx = try Fixtures()
        defer { fx.cleanup() }
        let recorder = StubURLProtocol.install()
        defer { StubURLProtocol.reset() }
        recorder.enqueue(status: 400, json: #"{"error":{"code":"INVALID_STATUS","message":"session not ready"}}"#)

        var caught: SessionUploadError?
        do {
            _ = try await makeClient().uploadAudio(
                sessionId: "s", therapistAudioURL: fx.mic, clientAudioURL: nil, onProgress: { _ in }
            )
        } catch let error as SessionUploadError {
            caught = error
        }
        #expect(caught?.statusCode == 400)
        #expect(caught?.code == "INVALID_STATUS")
        #expect(caught?.message == "session not ready")
    }

    // MARK: - uploadWithSelfHeal

    @Test("INVALID_STATUS heals: PATCH to recording_complete, then a second upload succeeds")
    func selfHealRecoversInvalidStatus() async throws {
        let fx = try Fixtures()
        defer { fx.cleanup() }
        let recorder = StubURLProtocol.install()
        defer { StubURLProtocol.reset() }
        // 1st upload → 400 INVALID_STATUS, PATCH → 200, 2nd upload → 200.
        recorder.enqueue(status: 400, json: #"{"error":{"code":"INVALID_STATUS","message":"still recording"}}"#)
        recorder.enqueue(status: 200, json: "{}")
        recorder.enqueue(status: 200, json: #"{"id":"s","status":"transcribing","queue":null,"message":"healed"}"#)

        let response = try await makeClient().uploadWithSelfHeal(
            sessionId: "s", therapistAudioURL: fx.mic, clientAudioURL: nil
        )
        #expect(response.message == "healed")

        // Three requests: upload, status PATCH, upload.
        #expect(recorder.captured.count == 3)
        #expect(recorder.captured[0].url?.path == "/api/sessions/s/upload-audio")
        let patch = recorder.captured[1]
        #expect(patch.url?.path == "/api/sessions/s/status")
        #expect(patch.httpMethod == "PATCH")
        #expect(bodyString(patch.capturedBody).contains("recording_complete"))
        #expect(recorder.captured[2].url?.path == "/api/sessions/s/upload-audio")
    }

    @Test("A non-INVALID_STATUS error propagates without a self-heal PATCH")
    func selfHealDoesNotSwallowOtherErrors() async throws {
        let fx = try Fixtures()
        defer { fx.cleanup() }
        let recorder = StubURLProtocol.install()
        defer { StubURLProtocol.reset() }
        recorder.enqueue(status: 403, json: #"{"error":{"code":"FORBIDDEN","message":"nope"}}"#)

        var caught: SessionUploadError?
        do {
            _ = try await makeClient().uploadWithSelfHeal(
                sessionId: "s", therapistAudioURL: fx.mic, clientAudioURL: nil
            )
        } catch let error as SessionUploadError {
            caught = error
        }
        #expect(caught?.statusCode == 403)
        // Only the single failed upload — no PATCH, no retry.
        #expect(recorder.captured.count == 1)
    }

    @Test("A first-try success does not PATCH or retry")
    func selfHealNoOpOnSuccess() async throws {
        let fx = try Fixtures()
        defer { fx.cleanup() }
        let recorder = StubURLProtocol.install()
        defer { StubURLProtocol.reset() }
        recorder.enqueue(status: 200, json: #"{"id":"s","status":"transcribing","queue":null,"message":"ok"}"#)

        _ = try await makeClient().uploadWithSelfHeal(
            sessionId: "s", therapistAudioURL: fx.mic, clientAudioURL: nil
        )
        #expect(recorder.captured.count == 1)
    }

    // MARK: - updateSessionStatus

    @Test("updateSessionStatus PATCHes the status body with binding attached")
    func updateStatusSendsBody() async throws {
        let recorder = StubURLProtocol.install()
        defer { StubURLProtocol.reset() }
        recorder.enqueue(status: 200, json: "{}")
        let binding = BindingRecorder()

        try await makeClient(bindingCalls: binding).updateSessionStatus(sessionId: "s", status: "recording_complete")

        let sent = try #require(recorder.captured.first)
        #expect(sent.httpMethod == "PATCH")
        #expect(sent.url?.path == "/api/sessions/s/status")
        #expect(bodyString(sent.capturedBody).contains("recording_complete"))
        #expect(binding.count == 1)
    }
}

// MARK: - Test doubles

/// Decodes request-body bytes for substring assertions. Uses Latin-1 (never
/// fails, maps every byte 1:1) because the multipart body now carries binary
/// WAV headers — a UTF-8 decode would return nil on those bytes.
private func bodyString(_ data: Data) -> String {
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
