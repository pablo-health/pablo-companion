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

    // MARK: - uploadAudioViaSignedURL / uploadWithSelfHeal (signed-URL path)

    /// The canned `…/upload-audio/init` body: two signed PUT recipes to a fake
    /// storage host, each carrying the signed Content-Type +
    /// x-goog-content-length-range the client must replay verbatim.
    private static let therapistPutURL = "https://storage.test/signed/s/therapist.pcm?sig=t"
    private static let clientPutURL = "https://storage.test/signed/s/client.pcm?sig=c"
    private static let initJSON = """
    {
      "session_id": "s",
      "therapist": {
        "upload": {
          "url": "\(therapistPutURL)",
          "method": "PUT",
          "headers": {"Content-Type": "application/octet-stream", "x-goog-content-length-range": "0,1048576000"},
          "fields": {}
        },
        "gcs_path": "signed/s/therapist.pcm"
      },
      "client": {
        "upload": {
          "url": "\(clientPutURL)",
          "method": "PUT",
          "headers": {"Content-Type": "application/octet-stream", "x-goog-content-length-range": "0,1048576000"},
          "fields": {}
        },
        "gcs_path": "signed/s/client.pcm"
      },
      "max_bytes": 1048576000
    }
    """

    @Test("Signed-URL upload: init → PUT each channel (correct headers, streamed) → finalize")
    func signedUploadHappyPath() async throws {
        let fx = try Fixtures()
        defer { fx.cleanup() }
        let recorder = StubURLProtocol.install()
        defer { StubURLProtocol.reset() }
        recorder.enqueue(status: 201, json: Self.initJSON)
        recorder.enqueue(status: 200, json: "") // therapist PUT (GCS returns empty body)
        recorder.enqueue(status: 200, json: "") // client PUT
        recorder.enqueue(
            status: 202,
            json: #"{"id":"s","status":"transcribing","provider":"assemblyai","queue":"","message":"queued"}"#
        )

        let response = try await makeClient().uploadWithSelfHeal(
            sessionId: "s", therapistAudioURL: fx.mic, clientAudioURL: fx.system
        )
        #expect(response.status == "transcribing")

        // init → PUT therapist → PUT client → finalize, in order.
        #expect(recorder.captured.count == 4)

        let initReq = recorder.captured[0]
        #expect(initReq.url?.path == "/api/sessions/s/upload-audio/init")
        #expect(initReq.httpMethod == "POST")
        #expect(initReq.value(forHTTPHeaderField: "Authorization") == "Bearer test-bearer")
        #expect(initReq.value(forHTTPHeaderField: "DPoP") == "proof-abc")

        let therapistPut = recorder.captured[1]
        #expect(therapistPut.url?.absoluteString == Self.therapistPutURL)
        #expect(therapistPut.httpMethod == "PUT")
        #expect(therapistPut.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        #expect(therapistPut.value(forHTTPHeaderField: "x-goog-content-length-range") == "0,1048576000")
        // The signed URL is the auth: no Bearer, no DPoP on the storage PUT.
        #expect(therapistPut.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(therapistPut.value(forHTTPHeaderField: "DPoP") == nil)
        // Streamed from disk as a real WAV (RIFF header prepended to the PCM).
        let therapistBody = bodyString(therapistPut.capturedBody)
        #expect(therapistBody.hasPrefix("RIFF"))
        #expect(therapistBody.contains("mic-bytes"))

        let clientPut = recorder.captured[2]
        #expect(clientPut.url?.absoluteString == Self.clientPutURL)
        #expect(clientPut.httpMethod == "PUT")
        #expect(clientPut.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(bodyString(clientPut.capturedBody).contains("system-bytes"))

        let finalizeReq = recorder.captured[3]
        #expect(finalizeReq.url?.path == "/api/sessions/s/upload-audio/finalize")
        #expect(finalizeReq.httpMethod == "POST")
        #expect(finalizeReq.value(forHTTPHeaderField: "Authorization") == "Bearer test-bearer")
        #expect(finalizeReq.value(forHTTPHeaderField: "DPoP") == "proof-abc")
    }

    @Test("Signed-URL finalize INVALID_STATUS heals: PATCH then re-finalize, no re-upload")
    func signedUploadHealsInvalidStatus() async throws {
        let fx = try Fixtures()
        defer { fx.cleanup() }
        let recorder = StubURLProtocol.install()
        defer { StubURLProtocol.reset() }
        recorder.enqueue(status: 201, json: Self.initJSON)
        recorder.enqueue(status: 200, json: "") // therapist PUT
        recorder.enqueue(status: 200, json: "") // client PUT
        recorder.enqueue(status: 400, json: #"{"error":{"code":"INVALID_STATUS","message":"still recording"}}"#)
        recorder.enqueue(status: 200, json: "{}") // PATCH status
        recorder.enqueue(status: 200, json: #"{"id":"s","status":"transcribing","queue":null,"message":"healed"}"#)

        let response = try await makeClient().uploadWithSelfHeal(
            sessionId: "s", therapistAudioURL: fx.mic, clientAudioURL: fx.system
        )
        #expect(response.message == "healed")

        // init, PUT, PUT, finalize(400), PATCH, finalize(200) — audio uploaded once.
        #expect(recorder.captured.count == 6)
        #expect(recorder.captured[1].url?.absoluteString == Self.therapistPutURL)
        #expect(recorder.captured[2].url?.absoluteString == Self.clientPutURL)
        #expect(recorder.captured[3].url?.path == "/api/sessions/s/upload-audio/finalize")
        let patch = recorder.captured[4]
        #expect(patch.url?.path == "/api/sessions/s/status")
        #expect(patch.httpMethod == "PATCH")
        #expect(bodyString(patch.capturedBody).contains("recording_complete"))
        #expect(recorder.captured[5].url?.path == "/api/sessions/s/upload-audio/finalize")
    }

    @Test("Signed-URL: a GCS PUT non-2xx surfaces as SessionUploadError, no finalize")
    func signedUploadGcsPutFailurePropagates() async throws {
        let fx = try Fixtures()
        defer { fx.cleanup() }
        let recorder = StubURLProtocol.install()
        defer { StubURLProtocol.reset() }
        recorder.enqueue(status: 201, json: Self.initJSON)
        // GCS rejects the PUT (e.g. signature mismatch) with an XML body.
        recorder.enqueue(
            status: 403,
            json: "<?xml version='1.0'?><Error><Code>SignatureDoesNotMatch</Code></Error>"
        )

        var caught: SessionUploadError?
        do {
            _ = try await makeClient().uploadWithSelfHeal(
                sessionId: "s", therapistAudioURL: fx.mic, clientAudioURL: fx.system
            )
        } catch let error as SessionUploadError {
            caught = error
        }
        #expect(caught?.statusCode == 403)
        #expect(caught?.message?.contains("SignatureDoesNotMatch") == true)
        // init + the failed therapist PUT only — no client PUT, no finalize.
        #expect(recorder.captured.count == 2)
    }

    @Test("Signed-URL: a non-INVALID_STATUS finalize error propagates without a PATCH")
    func signedUploadFinalizeErrorPropagates() async throws {
        let fx = try Fixtures()
        defer { fx.cleanup() }
        let recorder = StubURLProtocol.install()
        defer { StubURLProtocol.reset() }
        recorder.enqueue(status: 201, json: Self.initJSON)
        recorder.enqueue(status: 200, json: "")
        recorder.enqueue(status: 200, json: "")
        recorder.enqueue(status: 403, json: #"{"error":{"code":"FORBIDDEN","message":"nope"}}"#)

        var caught: SessionUploadError?
        do {
            _ = try await makeClient().uploadWithSelfHeal(
                sessionId: "s", therapistAudioURL: fx.mic, clientAudioURL: fx.system
            )
        } catch let error as SessionUploadError {
            caught = error
        }
        #expect(caught?.statusCode == 403)
        // init, PUT, PUT, finalize(403) — no PATCH, no re-finalize.
        #expect(recorder.captured.count == 4)
    }

    @Test("Signed-URL: missing client audio fails before any network call")
    func signedUploadRequiresClientChannel() async throws {
        let fx = try Fixtures()
        defer { fx.cleanup() }
        let recorder = StubURLProtocol.install()
        defer { StubURLProtocol.reset() }

        var caught: SessionUploadError?
        do {
            _ = try await makeClient().uploadWithSelfHeal(
                sessionId: "s", therapistAudioURL: fx.mic, clientAudioURL: nil
            )
        } catch let error as SessionUploadError {
            caught = error
        }
        #expect(caught != nil)
        #expect(recorder.captured.isEmpty)
    }

    // MARK: - wavFileForUpload

    @Test("wavFileForUpload wraps headerless PCM into a WAV temp file, streamed from disk")
    func wavFileWrapsRawPcm() throws {
        let fx = try Fixtures()
        defer { fx.cleanup() }
        let result = try AudioUploadClient.wavFileForUpload(source: fx.mic, sampleRate: 48000, channels: 1)
        defer { if result.isTemp { try? FileManager.default.removeItem(at: result.url) } }

        #expect(result.isTemp)
        let bytes = try Data(contentsOf: result.url)
        #expect(bytes.prefix(4) == Data("RIFF".utf8))
        // 44-byte header + the 9 raw PCM bytes ("mic-bytes").
        #expect(bytes.count == 44 + 9)
        #expect(bodyString(bytes).contains("mic-bytes"))
    }

    @Test("wavFileForUpload passes an already-RIFF source through untouched")
    func wavFilePassesThroughExistingWav() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("csc-wav-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("already.wav")
        let wavBytes = WAVEncoder.wrap(pcm: Data("pcm".utf8), sampleRate: 48000, channels: 1)
        try wavBytes.write(to: wav)

        let result = try AudioUploadClient.wavFileForUpload(source: wav, sampleRate: 48000, channels: 1)
        #expect(!result.isTemp)
        #expect(result.url == wav)
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
