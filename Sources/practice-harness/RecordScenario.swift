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
///                           otherwise gate at "transcribing". NOTE: dev calls
///                           AssemblyAI for real — the old "whisper→mock" note was stale.
///   RECORD_POLL_SECONDS     SOAP poll deadline when expecting SOAP (default 300)
///   RECORD_ALLOW_TRANSCRIPTION_OFF  "1" to pass when the upload answers 501
///                           (transcription off). Only for a stack with no ASR;
///                           on dev and prod a 501 fails the gate.
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

        // Mint a fresh device key rather than reading one an earlier build left
        // behind. macOS ties a Keychain ACL to the binary that created an item,
        // and an unsigned CLI is a different binary after every rebuild — so
        // reading the old key raises a system prompt and blocks forever in
        // SecItemCopyMatching with nobody to click it. Creating never prompts.
        // The harness enrols a new install_id each run, so the old key is dead
        // weight regardless.
        DeviceKey.resetPersistedKeys()

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
                pollSeconds: Double(env["RECORD_POLL_SECONDS"] ?? "") ?? 300,
                allowTranscriptionOff: SoapGate.allowsTranscriptionOff(env: env)
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
    let allowTranscriptionOff: Bool

    func run() async throws {
        var checks: [GateCheck] = []
        let installID = UUID().uuidString.lowercased()
        let client = DeviceBoundClient(baseURL: baseURL, installID: installID)
        RecordScenario.log("install_id for this run: \(installID)")

        // ── 1. Enrollment ────────────────────────────────────────────────
        let enrollment = try await client.enroll(idToken: idToken, refreshToken: refreshToken)
        let token = enrollment.idToken
        checks.append(GateCheck(
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
        checks.append(GateCheck(name: "session scheduled", ok: true, detail: "id \(sessionID)"))

        // Move to in_progress only — the upload self-heal must drive the
        // recording_complete transition (that's the path under test).
        let inProgress = try await client.request(
            "PATCH", path: "/api/sessions/\(sessionID)/status", idToken: token,
            jsonBody: ["status": "in_progress"]
        )
        checks.append(GateCheck(
            name: "session in_progress",
            ok: inProgress.status == 200,
            detail: "status \(inProgress.status)"
        ))

        // ── 3. Record through the real capture graph from file fixtures ───
        let recording = try await FixtureCapture(
            micFixture: micFixture, systemFixture: systemFixture, seconds: recordSeconds
        ).record(touch: {
            _ = try? await client.request("POST", path: "/api/auth/session/touch", idToken: token)
        })
        checks += recording.checks(seconds: recordSeconds)

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

        // Go through the real queue rather than calling the client directly.
        //
        // The app never uploads inline: it enqueues to PendingAudioUploadStore
        // first — the durability anchor that survives a crash or sign-out — and
        // a coordinator drains it, applies the backoff ladder, and deletes the
        // local audio once the backend confirms. Calling uploadWithSelfHeal here
        // skipped all of that, so a passing 50-minute run said nothing about the
        // queue, the retry accounting, or whether the recording was ever cleaned
        // up. Those are the paths a therapist's session actually depends on.
        let storeDir = recording.micURL.deletingLastPathComponent()
            .appendingPathComponent("pending", isDirectory: true)
        var store = PendingAudioUploadStore(
            directory: storeDir,
            makeEncryptor: { _ in PassthroughEncryptor() }
        )
        store.userEmail = "harness@pablo.health"

        store.add(
            sessionId: sessionID,
            micPath: recording.micURL.path,
            systemPath: recording.systemURL?.path,
            isEncrypted: false,
            // The fixtures are generated at 48 kHz and the capture graph runs at
            // that rate, so the harness stamps 48 kHz explicitly.
            sampleRate: 48000
        )
        checks.append(GateCheck(
            name: "queued before upload (durability anchor)",
            ok: store.get(sessionId: sessionID) != nil,
            detail: "1 entry"
        ))

        let uploadStatus = Box<String?>(nil)
        let uploadError = Box<Error?>(nil)
        let coordinator = PendingAudioUploadCoordinator(
            store: store,
            upload: { entry in
                do {
                    let uploaded = try await uploadClient.uploadWithSelfHeal(
                        sessionId: entry.sessionId,
                        therapistAudioURL: URL(fileURLWithPath: entry.micPath),
                        clientAudioURL: entry.systemPath.map { URL(fileURLWithPath: $0) },
                        sampleRate: Int(entry.sampleRate ?? 48000)
                    )
                    uploadStatus.value = uploaded.status
                } catch {
                    uploadError.value = error
                    throw error
                }
            },
            cleanup: { entry in
                RecordingCleaner.removeAudio(micPath: entry.micPath, systemPath: entry.systemPath)
            }
        )

        do {
            let drained = await coordinator.drain()

            if let error = uploadError.value {
                throw error
            }

            checks.append(GateCheck(
                name: "upload accepted + transcribing",
                ok: drained == 1 && uploadStatus.value == "transcribing",
                detail: "status \(uploadStatus.value ?? "none")"
            ))
            checks.append(GateCheck(
                name: "queue drained after success",
                ok: store.get(sessionId: sessionID) == nil,
                detail: "0 entries"
            ))
            // The PHI-retention gate: audio must not outlive a confirmed upload.
            let micGone = !FileManager.default.fileExists(atPath: recording.micURL.path)
            let systemGone = recording.systemURL.map {
                !FileManager.default.fileExists(atPath: $0.path)
            } ?? true
            checks.append(GateCheck(
                name: "local audio deleted after confirmed upload",
                ok: micGone && systemGone,
                detail: micGone && systemGone ? "sidecars removed" : "sidecars still on disk"
            ))
        } catch let error as SessionUploadError where error.statusCode == 501 {
            RecordScenario.log("upload-audio 501: transcription is off on \(baseURL)")
            checks.append(SoapGate.transcriptionOffCheck(allowed: allowTranscriptionOff))
            try GateSummary.report(checks, title: "record gate summary", passed: "RECORD GATE PASSED ✓")
            return
        }

        // ── 5. Poll for the SOAP ──────────────────────────────────────────
        if expectSoap {
            try await checks.append(
                SoapGate(client: client, idToken: token, pollSeconds: pollSeconds).poll(sessionID: sessionID)
            )
        } else {
            RecordScenario.log("RECORD_EXPECT_SOAP != 1 — gating at 'transcribing'; set it to poll for the real SOAP")
        }

        try GateSummary.report(checks, title: "record gate summary", passed: "RECORD GATE PASSED ✓")
    }
}

#endif
