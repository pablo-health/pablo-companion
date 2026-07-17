import Foundation
import PracticeClientCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Headless driver for the real practice-mode client.
///
/// Connects the actual `PracticeAPIClient` + `PracticeWebSocketClient` to a
/// deployed backend, replays a PCM fixture in place of the microphone, and
/// captures the patient-voice audio + transcript frames that come back. This
/// is the "does the real client work end to end" probe — no protocol
/// reimplementation, so it can't drift from the shipping client.
///
/// Configuration (env):
///   PRACTICE_SCENARIO      "practice" (default), "dpop" (device binding, in
///                          DPoPScenario.swift), or "record" (recording →
///                          upload → SOAP, in RecordScenario.swift) — macOS only
///   PRACTICE_BASE_URL      backend base URL (default https://app.pablo.health)
///   PRACTICE_AUDIO         path to raw s16le 16 kHz mono PCM fixture (required)
///   PRACTICE_TOPIC         topic id (default: first from /api/practice/topics)
///   PRACTICE_RESPONSE_WAIT seconds to wait for patient audio after streaming
///                          (default 20)
///
/// Auth — the harness signs the pinned test user in itself (no Node, no prior
/// e2e state). Refresh token is tried first; on any failure it falls back to
/// the full TOTP MFA flow.
///   PRACTICE_BEARER_TOKEN  pre-minted ID token override (skips sign-in)
///   FB_API_KEY             Firebase API key (required unless BEARER_TOKEN set)
///   FB_REFRESH_TOKEN       cached refresh token (fast path)
///   FB_EMAIL/FB_PASSWORD/FB_TOTP_SECRET  TOTP MFA fallback creds
///   REFRESH_OUT            file to write the rotated refresh token to (so a
///                          wrapper can persist it back to Secret Manager)
@main
struct PracticeHarness {
    static func main() async {
        let env = ProcessInfo.processInfo.environment
        let baseURL = env["PRACTICE_BASE_URL"] ?? "https://app.pablo.health"

        if env["PRACTICE_SCENARIO"] == "dpop" {
            #if canImport(CompanionAuthCore)
            await DPoPScenario.run(env: env)
            return
            #else
            fail("The dpop scenario needs CompanionAuthCore (macOS only).")
            #endif
        }

        if env["PRACTICE_SCENARIO"] == "record" {
            #if canImport(CompanionAuthCore)
            await RecordScenario.run(env: env)
            return
            #else
            fail("The record scenario needs CompanionAuthCore (macOS only).")
            #endif
        }

        guard let audioPath = env["PRACTICE_AUDIO"], !audioPath.isEmpty else {
            fail("PRACTICE_AUDIO is required (path to raw s16le 16kHz mono PCM).")
        }
        let audioURL = URL(fileURLWithPath: audioPath)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            fail("Audio fixture not found: \(audioURL.path)")
        }

        let responseWait = Double(env["PRACTICE_RESPONSE_WAIT"] ?? "") ?? 20

        let token: String
        if let preset = env["PRACTICE_BEARER_TOKEN"], !preset.isEmpty {
            log("Using preset PRACTICE_BEARER_TOKEN")
            token = preset
        } else {
            guard let apiKey = env["FB_API_KEY"], !apiKey.isEmpty else {
                fail("FB_API_KEY is required to mint a token (or set PRACTICE_BEARER_TOKEN).")
            }
            do {
                let result = try await FirebaseAuth(apiKey: apiKey).mint(
                    refreshToken: env["FB_REFRESH_TOKEN"],
                    email: env["FB_EMAIL"],
                    password: env["FB_PASSWORD"],
                    totpSecret: env["FB_TOTP_SECRET"]
                )
                log("Signed in via \(result.mode)")
                token = result.idToken
                if let refreshOut = env["REFRESH_OUT"], !refreshOut.isEmpty {
                    try? result.refreshToken.write(toFile: refreshOut, atomically: true, encoding: .utf8)
                }
            } catch {
                fail("Sign-in failed: \(error.localizedDescription)")
            }
        }

        do {
            try await Runner(
                baseURL: baseURL,
                token: token,
                audioURL: audioURL,
                topicId: env["PRACTICE_TOPIC"],
                responseWait: responseWait
            ).run()
        } catch {
            fail("Run failed: \(error.localizedDescription)")
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8))
        exit(2)
    }
}

/// Thread-safe collector for WebSocket events (callbacks fire off the main actor).
private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var authOk = false
    private(set) var sessionStarted = false
    private(set) var sessionEnded = false
    private(set) var fatal: String?
    private(set) var asrRecognized = 0
    private(set) var serverFrames = 0

    func markStarted() { lock.lock(); sessionStarted = true; lock.unlock() }
    func markEnded() { lock.lock(); sessionEnded = true; lock.unlock() }
    func markFatal(_ message: String) { lock.lock(); fatal = message; lock.unlock() }

    func recordServerEvent(_ raw: String) {
        lock.lock()
        serverFrames += 1
        if contains(raw, "auth_result"), contains(raw, "ok") {
            authOk = true
        }
        // The server never forwards transcript *text*. Instead it emits a
        // `status`/`processing` frame the instant ASR finalises a therapist
        // utterance and the patient turn begins — that is the faithful
        // "our streamed audio was recognised" signal.
        if contains(raw, "status"), contains(raw, "processing") {
            asrRecognized += 1
        }
        lock.unlock()
    }

    /// Substring match for a JSON value, tolerant of `json.dumps` spacing.
    private func contains(_ raw: String, _ value: String) -> Bool {
        raw.contains("\"\(value)\"")
    }

    var snapshot: (authOk: Bool, started: Bool, ended: Bool, fatal: String?, asr: Int, frames: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (authOk, sessionStarted, sessionEnded, fatal, asrRecognized, serverFrames)
    }
}

@MainActor
private struct Runner {
    let baseURL: String
    let token: String
    let audioURL: URL
    let topicId: String?
    let responseWait: Double

    func run() async throws {
        let api = PracticeAPIClient()
        api.baseURL = baseURL
        let token = self.token
        api.getToken = { token }

        // Resolve a topic.
        let topic: String
        if let topicId { topic = topicId } else {
            let topics = try await api.fetchTopics()
            guard let first = topics.first else {
                throw RunError.message("No practice topics available on \(baseURL)")
            }
            topic = first.id
            log("Using topic: \(first.id) (\(first.name))")
        }

        // 1. Create session.
        let session = try await api.createSession(topicId: topic)
        log("Created session: \(session.sessionId)")

        let events = Events()
        let sink = CapturingAudioSink()
        let ws = PracticeWebSocketClient()

        ws.onServerEvent = { raw in
            events.recordServerEvent(raw)
            log("⇠ \(raw.prefix(240))")
        }
        ws.onAudioReceived = { pcm, isFinal in
            sink.enqueue(pcm)
            if isFinal { log("⇠ [patient audio: final chunk]") }
        }
        ws.onSessionStarted = { _ in events.markStarted() }
        ws.onSessionEnded = { _ in events.markEnded() }
        ws.onError = { message, fatal in
            if fatal { events.markFatal(message) }
            log("⇠ error (fatal=\(fatal)): \(message)")
        }

        // 2. Connect WebSocket with the single-use ticket.
        guard let wsURL = api.webSocketURL(ticket: session.wsTicket) else {
            throw RunError.message("Could not build WebSocket URL")
        }
        ws.connect(url: wsURL)

        // 3. Auth settles, then start the session.
        try await Task.sleep(for: .milliseconds(500))
        ws.startSession(sessionId: session.sessionId)

        // 4. Wait for session_started (server inits ASR/Gemini/TTS, ~5-10s).
        try await waitUntil(timeout: 30) { events.snapshot.started || events.snapshot.fatal != nil }
        if let fatal = events.snapshot.fatal { throw RunError.message("Fatal before stream: \(fatal)") }
        guard events.snapshot.started else { throw RunError.message("Timed out waiting for session_started") }
        log("Session active — streaming fixture")

        // 5. Replay the fixture as 20ms frames at real-time cadence.
        let source = try FileAudioInputSource(pcmURL: audioURL)
        source.onAudioFrame = { frame in ws.sendAudioFrame(frame) }
        try source.start()
        try await waitUntil(timeout: 120) { source.didFinish }
        source.stop()
        log("Fixture streamed — waiting up to \(Int(responseWait))s for patient response")

        // 6. Give the patient turn time to come back, then end.
        try await Task.sleep(for: .seconds(responseWait))
        ws.endSession()
        try await waitUntil(timeout: 15) { events.snapshot.ended }

        // 7. Fetch the generated SOAP note. The server builds it during
        //    session_end (before sending the frame), but poll briefly in case
        //    the persistence write trails the frame.
        var soap: PracticeSoapNote?
        let soapDeadline = Date().addingTimeInterval(30)
        while Date() < soapDeadline {
            if let detail = try? await api.getSessionDetail(sessionId: session.sessionId),
               let note = detail.soapNote {
                soap = note
                break
            }
            try await Task.sleep(for: .seconds(2))
        }

        // 8. Clean up the practice session we created.
        try? await api.endSession(sessionId: session.sessionId)
        ws.disconnect()

        // 9. Evaluate the gate — structural + audio-liveness only (per design).
        try evaluate(events: events, sink: sink, soap: soap, sessionId: session.sessionId)
    }

    /// Asserts the structural + VAD/RMS gate and throws (non-zero exit) on any miss.
    private func evaluate(events: Events, sink: CapturingAudioSink, soap: PracticeSoapNote?, sessionId: String) throws {
        let snap = events.snapshot
        let rms = sink.rms()
        let minRMS = Double(ProcessInfo.processInfo.environment["PRACTICE_MIN_RMS"] ?? "") ?? 0.01

        let soapDetail: String
        if let soap {
            soapDetail = soap.isComplete ? "all four sections present" : "a section was empty"
        } else {
            soapDetail = "no soap_note returned"
        }

        let checks: [(name: String, ok: Bool, detail: String)] = [
            ("auth_result ok", snap.authOk, snap.authOk ? "" : "no auth_result:ok frame"),
            ("session_started", snap.started, snap.started ? "" : "server never started the session"),
            ("asr recognised speech", snap.asr >= 1, "status:processing frames = \(snap.asr)"),
            ("patient voice frames", sink.chunkCount >= 1, "\(sink.chunkCount) chunks, \(sink.captured.count) bytes"),
            ("patient audio is speech", rms >= minRMS, String(format: "RMS %.4f (min %.4f)", rms, minRMS)),
            ("session_ended", snap.ended, snap.ended ? "" : "no session_ended frame"),
            ("4-section SOAP", soap?.isComplete == true, soapDetail),
        ]

        let pad = checks.map(\.name.count).max() ?? 0
        let lines = checks
            .map { "  [\($0.ok ? "PASS" : "FAIL")] \($0.name.padding(toLength: pad, withPad: " ", startingAt: 0))  \($0.detail)" }
            .joined(separator: "\n")
        log("""
        ───── gate summary (session \(sessionId)) ─────
        \(lines)
          server frames: \(snap.frames)
        ─────────────────────────────────────────
        """)

        let failed = checks.filter { !$0.ok }.map(\.name)
        if !failed.isEmpty {
            throw RunError.message("Gate FAILED: \(failed.joined(separator: ", "))")
        }
        log("GATE PASSED ✓")
    }

    private func waitUntil(timeout: Double, _ condition: @escaping @Sendable () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

private enum RunError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(m) = self { m } else { nil } }
}

private func log(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}
