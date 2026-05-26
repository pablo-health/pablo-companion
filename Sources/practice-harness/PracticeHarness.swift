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
    private(set) var sessionStarted = false
    private(set) var sessionEnded = false
    private(set) var fatal: String?
    private(set) var finalTranscripts = 0
    private(set) var serverFrames = 0

    func markStarted() { lock.lock(); sessionStarted = true; lock.unlock() }
    func markEnded() { lock.lock(); sessionEnded = true; lock.unlock() }
    func markFatal(_ message: String) { lock.lock(); fatal = message; lock.unlock() }

    func recordServerEvent(_ raw: String) {
        lock.lock()
        serverFrames += 1
        // Count "final" transcript frames as the structural ASR signal.
        if raw.contains("\"transcript\""), raw.contains("\"is_final\":true") || raw.contains("\"final\":true") {
            finalTranscripts += 1
        }
        lock.unlock()
    }

    var snapshot: (started: Bool, ended: Bool, fatal: String?, finals: Int, frames: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (sessionStarted, sessionEnded, fatal, finalTranscripts, serverFrames)
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

        // 7. Clean up the created session in the test tenant.
        try? await api.endSession(sessionId: session.sessionId)
        ws.disconnect()

        // 8. Report (structural signal only for this increment — no gating yet).
        let snap = events.snapshot
        let captured = sink.captured
        log("""
        ───── summary ─────
        session:            \(session.sessionId)
        server frames:      \(snap.frames)
        final transcripts:  \(snap.finals)
        patient audio:      \(captured.count) bytes in \(sink.chunkCount) chunks
        patient audio RMS:  \(String(format: "%.4f", sink.rms()))
        session_ended:      \(snap.ended)
        ───────────────────
        """)

        if captured.isEmpty {
            throw RunError.message("No patient audio received — client→server path likely not exercised")
        }
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
