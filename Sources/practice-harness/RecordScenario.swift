#if canImport(CompanionAuthCore)

import AudioCaptureKit
import AVFoundation
import CompanionAuthCore
import CompanionSessionCore
import Foundation

/// `PRACTICE_SCENARIO=record` — drives the REAL Surface-A recording path against
/// a deployed backend, end to end:
///
///   sign in (pinned test user) → device enroll (DPoP) → seed patient + schedule
///   session → **record through the real AudioCaptureKit graph** (mic + system
///   fixtures injected via `FilePlayerCaptureSource`, `.separated` / 48 kHz /
///   raw-PCM sidecars — the exact `RecordingService` config) → **upload via the
///   real client wire path** (`CompanionSessionCore.AudioUploadClient`) → poll
///   the session to `transcribing` (dev) or `pending_review` + a 4-section SOAP
///   (prod, real ASR).
///
/// The session is left in `in_progress` (not `recording_complete`) before the
/// upload, so the first attempt returns `400 INVALID_STATUS` and the shared
/// self-heal recovers it — exercising that path on the live backend.
///
/// Environment:
///   PRACTICE_BASE_URL       backend base URL
///   FB_API_KEY + FB_* creds same sign-in plumbing as the other scenarios
///   RECORD_MIC_AUDIO        path to the therapist (mic) WAV fixture (required)
///   RECORD_SYSTEM_AUDIO     path to the client (system) WAV fixture (required)
///   RECORD_SECONDS          capture duration (default 20)
///   RECORD_EXPECT_SOAP      "1" to poll for the full SOAP (prod/assemblyai);
///                           otherwise gate at "transcribing" (dev whisper→mock)
///   RECORD_POLL_SECONDS     SOAP poll deadline when expecting SOAP (default 300)
enum RecordScenario {
    static func run(env: [String: String]) async {
        let baseURL = env["PRACTICE_BASE_URL"] ?? "https://app.pablo.health"

        guard let micPath = env["RECORD_MIC_AUDIO"], !micPath.isEmpty,
              let systemPath = env["RECORD_SYSTEM_AUDIO"], !systemPath.isEmpty
        else {
            PracticeHarness.fail("RECORD_MIC_AUDIO and RECORD_SYSTEM_AUDIO are required (WAV fixture paths).")
        }
        let micFixture = URL(fileURLWithPath: micPath)
        let systemFixture = URL(fileURLWithPath: systemPath)
        for fixture in [micFixture, systemFixture] where !FileManager.default.fileExists(atPath: fixture.path) {
            PracticeHarness.fail("Audio fixture not found: \(fixture.path)")
        }

        // Namespace the harness's keychain rows away from any real install; an
        // unsigned CLI has no keychain entitlements (see AuthCoreConfig).
        AuthCoreConfig.bundleID = "health.pablo.companion.harness"
        AuthCoreConfig.keychainAccessGroup = nil

        guard let apiKey = env["FB_API_KEY"], !apiKey.isEmpty else {
            PracticeHarness.fail("FB_API_KEY is required for the record scenario.")
        }

        do {
            let auth = try await FirebaseAuth(apiKey: apiKey).mint(
                refreshToken: env["FB_REFRESH_TOKEN"],
                email: env["FB_EMAIL"],
                password: env["FB_PASSWORD"],
                totpSecret: env["FB_TOTP_SECRET"]
            )
            log("Signed in via \(auth.mode)")
            if let refreshOut = env["REFRESH_OUT"], !refreshOut.isEmpty {
                try? auth.refreshToken.write(toFile: refreshOut, atomically: true, encoding: .utf8)
            }
            try await Driver(
                baseURL: baseURL,
                idToken: auth.idToken,
                refreshToken: auth.refreshToken,
                micFixture: micFixture,
                systemFixture: systemFixture,
                recordSeconds: Double(env["RECORD_SECONDS"] ?? "") ?? 20,
                expectSoap: env["RECORD_EXPECT_SOAP"] == "1",
                pollSeconds: Double(env["RECORD_POLL_SECONDS"] ?? "") ?? 300
            ).run()
        } catch {
            PracticeHarness.fail("record scenario failed: \(error.localizedDescription)")
        }
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}

private struct Driver {
    let baseURL: String
    let idToken: String
    let refreshToken: String
    let micFixture: URL
    let systemFixture: URL
    let recordSeconds: Double
    let expectSoap: Bool
    let pollSeconds: Double

    static let soapSections = ["subjective", "objective", "assessment", "plan"]

    private struct Check {
        let name: String
        let ok: Bool
        let detail: String
    }

    func run() async throws {
        var checks: [Check] = []
        let installID = UUID().uuidString.lowercased()
        let client = DeviceBoundClient(baseURL: baseURL, installID: installID)
        RecordScenario.log("install_id for this run: \(installID)")

        // ── 1. Enrollment ────────────────────────────────────────────────
        let enrollment = try await client.enroll(idToken: idToken, refreshToken: refreshToken)
        let token = enrollment.idToken
        checks.append(Check(
            name: "enrollment accepted at /native/exchange",
            ok: enrollment.exchangeStatus == 200,
            detail: "status \(enrollment.exchangeStatus), key_storage=\(enrollment.keyStorage)"
        ))

        // ── 2. Seed patient + schedule session (as the companion) ─────────
        let noise = String(UUID().uuidString.prefix(8)).lowercased()
        let patient = try await client.request(
            "POST", path: "/api/patients", idToken: token,
            jsonBody: ["first_name": "E2E", "last_name": "Record-\(noise)", "status": "active"]
        )
        guard patient.status == 201 || patient.status == 200, let patientID = patient.json?["id"] as? String else {
            throw DeviceBoundError("patient create failed: \(patient.status) \(patient.bodyPrefix)")
        }

        let scheduled = try await client.request(
            "POST", path: "/api/sessions/schedule", idToken: token,
            jsonBody: ["patient_id": patientID, "scheduled_at": client.iso8601(Date()), "source": "companion"]
        )
        guard scheduled.status == 201 || scheduled.status == 200, let sessionID = scheduled.json?["id"] as? String
        else {
            throw DeviceBoundError("schedule failed: \(scheduled.status) \(scheduled.bodyPrefix)")
        }
        checks.append(Check(name: "session scheduled", ok: true, detail: "id \(sessionID)"))

        // Move to in_progress only — the upload self-heal must drive the
        // recording_complete transition (that's the path under test).
        let inProgress = try await client.request(
            "PATCH", path: "/api/sessions/\(sessionID)/status", idToken: token,
            jsonBody: ["status": "in_progress"]
        )
        checks.append(Check(
            name: "session in_progress",
            ok: inProgress.status == 200,
            detail: "status \(inProgress.status)"
        ))

        // ── 3. Record through the real capture graph from file fixtures ───
        let recording = try await recordFromFixtures()
        checks.append(Check(name: "capture completed", ok: recording.ok, detail: recording.detail))
        checks.append(Check(
            name: "per-channel audio liveness",
            ok: recording.micRMS > 1 && recording.systemRMS > 1,
            detail: String(format: "mic RMS %.0f, system RMS %.0f", recording.micRMS, recording.systemRMS)
        ))
        checks.append(Check(
            name: "no dropped samples",
            ok: recording.overflow == 0,
            detail: "overflow samples \(recording.overflow)"
        ))

        // ── 4. Upload via the real client wire path (with self-heal) ──────
        let uploadClient = AudioUploadClient(
            baseURLString: baseURL,
            token: { token },
            attachBinding: { request in
                guard let url = request.url, let method = request.httpMethod,
                      let proof = DPoPProof.make(method: method, url: url) else { return }
                request.setValue(proof, forHTTPHeaderField: "DPoP")
                request.setValue(installID, forHTTPHeaderField: "X-Install-ID")
            }
        )

        do {
            let uploaded = try await uploadClient.uploadWithSelfHeal(
                sessionId: sessionID,
                therapistAudioURL: recording.micURL,
                clientAudioURL: recording.systemURL
            )
            checks.append(Check(
                name: "upload accepted + transcribing",
                ok: uploaded.status == "transcribing",
                detail: "status \(uploaded.status)"
            ))
        } catch let error as SessionUploadError where error.statusCode == 501 {
            // Server-side transcription disabled on this env — the record path is
            // proven up to the upload; there is nothing further to gate.
            RecordScenario.log("upload-audio 501: transcription disabled on \(baseURL)")
            checks.append(Check(
                name: "upload path reached (transcription disabled, 501)",
                ok: true,
                detail: "status 501"
            ))
            try summarize(checks)
            return
        }

        // ── 5. Poll for the SOAP (prod/assemblyai only) ───────────────────
        if expectSoap {
            try await checks.append(pollForSoap(client: client, idToken: token, sessionID: sessionID))
        } else {
            RecordScenario.log("RECORD_EXPECT_SOAP != 1 — gating at 'transcribing' (dev runs whisper→mock)")
        }

        try summarize(checks)
    }

    // MARK: - Recording

    private struct RecordingOutcome {
        let ok: Bool
        let detail: String
        let micURL: URL
        let systemURL: URL?
        let micRMS: Double
        let systemRMS: Double
        let overflow: Int
    }

    /// Drives `CompositeCaptureSession` with the exact `RecordingService` config,
    /// injecting the mic + system fixtures through `FilePlayerCaptureSource`.
    private func recordFromFixtures() async throws -> RecordingOutcome {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        guard let micFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false
        ), let systemFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false
        ) else {
            throw DeviceBoundError("could not build capture formats")
        }

        let config = CaptureConfiguration(
            sampleRate: 48000,
            bitDepth: 16,
            channels: 2,
            outputDirectory: tempDir,
            enableMicCapture: true,
            enableSystemCapture: true,
            mixingStrategy: .separated,
            exportRawPCM: true
        )

        let session = CompositeCaptureSession(
            configuration: config,
            micSource: FilePlayerCaptureSource(fileURL: micFixture, format: micFormat, loop: true),
            systemSource: FilePlayerCaptureSource(fileURL: systemFixture, format: systemFormat, loop: true)
        )

        try session.configure(config)
        try await session.startCapture()
        try await Task.sleep(nanoseconds: UInt64(recordSeconds * 1_000_000_000))
        let result = try await session.stopCapture()

        let diag = session.diagnostics
        let micURL = result.rawPCMFileURLs.indices.contains(0) ? result.rawPCMFileURLs[0] : nil
        let systemURL = result.rawPCMFileURLs.indices.contains(1) ? result.rawPCMFileURLs[1] : nil
        guard let micURL else { throw DeviceBoundError("no mic PCM sidecar produced") }

        return RecordingOutcome(
            ok: diag.mixCycles >= 1 && diag.bytesWritten > 0,
            detail: "mixCycles \(diag.mixCycles), bytes \(diag.bytesWritten)",
            micURL: micURL,
            systemURL: systemURL,
            micRMS: Self.pcmRMS(micURL),
            systemRMS: systemURL.map(Self.pcmRMS) ?? 0,
            overflow: diag.micOverflowSamples + diag.systemOverflowSamples
        )
    }

    /// RMS of a raw signed-16-bit-LE PCM sidecar — a cheap "is this speech, not
    /// silence" liveness check on each captured channel.
    private static func pcmRMS(_ url: URL) -> Double {
        guard let data = try? Data(contentsOf: url), data.count >= 2 else { return 0 }
        let sampleCount = data.count / 2
        var sumSquares = 0.0
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0 ..< sampleCount {
                let value = Double(Int16(littleEndian: samples[i]))
                sumSquares += value * value
            }
        }
        return (sumSquares / Double(sampleCount)).squareRoot()
    }

    // MARK: - SOAP poll

    private func pollForSoap(client: DeviceBoundClient, idToken: String, sessionID: String) async throws -> Check {
        let deadline = Date().addingTimeInterval(pollSeconds)
        var lastStatus = "transcribing"
        while Date() < deadline {
            let poll = try await client.request("GET", path: "/api/sessions/\(sessionID)", idToken: idToken)
            guard poll.status == 200 else {
                throw DeviceBoundError("poll failed: \(poll.status) \(poll.bodyPrefix)")
            }
            lastStatus = (poll.json?["status"] as? String) ?? lastStatus
            if lastStatus == "failed" {
                return Check(name: "SOAP generated", ok: false, detail: "session status 'failed'")
            }
            if lastStatus == "pending_review" {
                let note = poll.json?["note"] as? [String: Any]
                dumpNote(note)
                return evaluateSoap(note)
            }
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        return Check(name: "SOAP generated", ok: false, detail: "deadline hit (last status '\(lastStatus)')")
    }

    /// Logs the generated SOAP note so a run can be eyeballed against the fixture
    /// audio. The session is always one the harness itself created in the pinned
    /// test tenant from synthetic `say` audio — never a real patient's note.
    private func dumpNote(_ note: [String: Any]?) {
        guard let note else {
            RecordScenario.log("generated note: nil")
            return
        }
        let content = note["content"] ?? [:]
        guard let data = try? JSONSerialization.data(
            withJSONObject: content, options: [.prettyPrinted, .sortedKeys]
        ), let text = String(data: data, encoding: .utf8) else { return }
        RecordScenario.log("""
        ───── generated SOAP (note_type=\(note["note_type"] ?? "?")) ─────
        \(text)
        ──────────────────────────────────────
        """)
    }

    /// Ports `sectionHasContent` from `asr-integration.spec.ts`: the embedded note
    /// is a 4-section SOAP with at least one section populated.
    private func evaluateSoap(_ note: [String: Any]?) -> Check {
        guard let note else { return Check(name: "SOAP generated", ok: false, detail: "no note on session") }
        guard (note["note_type"] as? String) == "soap" else {
            return Check(name: "SOAP generated", ok: false, detail: "note_type \(note["note_type"] ?? "nil")")
        }
        let content = note["content"] as? [String: Any] ?? [:]
        let present = Self.soapSections.filter { content[$0] != nil }
        let populated = Self.soapSections.filter { sectionHasContent(content[$0] as? [String: Any]) }
        return Check(
            name: "4-section SOAP with content",
            ok: present.count == Self.soapSections.count && !populated.isEmpty,
            detail: "\(present.count)/4 sections present, \(populated.count) populated"
        )
    }

    private func sectionHasContent(_ section: [String: Any]?) -> Bool {
        guard let section else { return false }
        for value in section.values {
            if let array = value as? [Any], array.contains(where: sentenceHasText) {
                return true
            }
            if sentenceHasText(value) {
                return true
            }
        }
        return false
    }

    /// Mirrors `sentenceHasText` from `asr-integration.spec.ts`: a value counts
    /// as content when it is an object carrying a non-empty `text` string. SOAP
    /// section values are `{text: …}` sentence objects (or arrays of them), not
    /// bare strings — the distinction the first prod run surfaced.
    private func sentenceHasText(_ value: Any) -> Bool {
        guard let object = value as? [String: Any], let text = object["text"] as? String else { return false }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // A sentence only counts as *audio-derived* content when it is anchored to
        // a transcript segment. The SOAP LLM emits well-formed placeholder
        // sentences ("No transcript provided.") with confidence 0 and no source
        // segments when transcription came back empty — the earlier prod run
        // passed the gate on exactly that. Require a real transcript anchor.
        let hasSource = !((object["source_segment_ids"] as? [Any])?.isEmpty ?? true)
        let confidence = (object["confidence_score"] as? NSNumber)?.doubleValue ?? 0
        return hasSource || confidence > 0
    }

    // MARK: - Summary

    private func summarize(_ checks: [Check]) throws {
        let pad = checks.map(\.name.count).max() ?? 0
        let lines = checks
            .map {
                "  [\($0.ok ? "PASS" : "FAIL")] \($0.name.padding(toLength: pad, withPad: " ", startingAt: 0))  \($0.detail)"
            }
            .joined(separator: "\n")
        RecordScenario.log("""
        ───── record gate summary ─────
        \(lines)
        ───────────────────────────────
        """)
        let failed = checks.filter { !$0.ok }.map(\.name)
        if !failed.isEmpty {
            throw DeviceBoundError("Gate FAILED: \(failed.joined(separator: ", "))")
        }
        RecordScenario.log("RECORD GATE PASSED ✓")
    }
}

#endif
