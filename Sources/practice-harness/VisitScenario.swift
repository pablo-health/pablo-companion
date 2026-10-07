#if canImport(CompanionAuthCore)

import CompanionAuthCore
import CompanionSessionCore
import Foundation

/// `PRACTICE_SCENARIO=visit` — the path a clinician takes for a telehealth
/// visit with a client nobody has asked about AI-assisted notes, as one flow:
///
///   sign in → device enroll (DPoP) → turn on asking clients → seed a client
///   and a telehealth appointment → the consent check reads "ask on the
///   recording", and the script names the practice's audio window → start the
///   session from the appointment saying so → record through the real capture
///   graph → the client answers on the recording →
///   - `VISIT_ANSWER=agree` (default): the answer is saved as given over
///     telehealth; stop, queue and upload through the real queue; poll to a
///     four-section SOAP; the local audio is kept until the note exists, then
///     deleted.
///   - `VISIT_ANSWER=decline`: the app's decline path — stop, discard every
///     file and queue entry (`RecordingCleaner.discardDeclined`), return the
///     session to a hand-written note, save the decline. Nothing is uploaded,
///     no audio is left, and a later recorded start is refused with
///     `CLIENT_DECLINED_AI_NOTES`.
///
/// Its own scenario rather than a `record` option: `record` starts from
/// `/api/sessions/schedule` and deliberately leaves the session `in_progress`
/// so the upload self-heal runs on the live backend. Starting from an
/// appointment through the consent gate would change what that gate proves.
///
/// The practice's ask-clients setting is put back as it was when the run
/// ends, pass or fail.
///
/// Environment: as `record` (PRACTICE_BASE_URL, FB_* sign-in, REFRESH_OUT,
/// RECORD_MIC_AUDIO, RECORD_SYSTEM_AUDIO, RECORD_SECONDS,
/// RECORD_POLL_SECONDS, RECORD_ALLOW_TRANSCRIPTION_OFF), plus VISIT_ANSWER.
enum VisitScenario {
    static func run(env: [String: String]) async {
        let baseURL = env["PRACTICE_BASE_URL"] ?? "https://app.pablo.health"
        let answer = env["VISIT_ANSWER"] ?? "agree"
        guard answer == "agree" || answer == "decline" else {
            PracticeHarness.fail("VISIT_ANSWER must be 'agree' or 'decline', not '\(answer)'.")
        }
        guard let micPath = env["RECORD_MIC_AUDIO"], !micPath.isEmpty,
              let systemPath = env["RECORD_SYSTEM_AUDIO"], !systemPath.isEmpty
        else {
            PracticeHarness.fail("RECORD_MIC_AUDIO and RECORD_SYSTEM_AUDIO are required (WAV fixture paths).")
        }
        for path in [micPath, systemPath] where !FileManager.default.fileExists(atPath: path) {
            PracticeHarness.fail("Audio fixture not found: \(path)")
        }
        guard let apiKey = env["FB_API_KEY"], !apiKey.isEmpty else {
            PracticeHarness.fail("FB_API_KEY is required for the visit scenario.")
        }

        // Same keychain handling as `record`: a namespace away from any real
        // install, and a fresh device key so no Keychain prompt can block.
        AuthCoreConfig.bundleID = "health.pablo.companion.harness"
        AuthCoreConfig.keychainAccessGroup = nil
        DeviceKey.resetPersistedKeys()

        do {
            let auth = try await FirebaseAuth(apiKey: apiKey).mint(
                refreshToken: env["FB_REFRESH_TOKEN"],
                email: env["FB_EMAIL"],
                password: env["FB_PASSWORD"],
                totpSecret: env["FB_TOTP_SECRET"]
            )
            GateSummary.log("Signed in via \(auth.mode)")
            if let refreshOut = env["REFRESH_OUT"], !refreshOut.isEmpty {
                try? auth.refreshToken.write(toFile: refreshOut, atomically: true, encoding: .utf8)
            }
            let seconds = Double(env["RECORD_SECONDS"] ?? "") ?? 20
            try await VisitDriver(
                baseURL: baseURL,
                installID: UUID().uuidString.lowercased(),
                capture: FixtureCapture(
                    micFixture: URL(fileURLWithPath: micPath),
                    systemFixture: URL(fileURLWithPath: systemPath),
                    seconds: seconds
                ),
                declines: answer == "decline",
                pollSeconds: Double(env["RECORD_POLL_SECONDS"] ?? "") ?? 300,
                allowTranscriptionOff: SoapGate.allowsTranscriptionOff(env: env)
            ).run(idToken: auth.idToken, refreshToken: auth.refreshToken)
        } catch {
            PracticeHarness.fail("visit scenario failed: \(error.localizedDescription)")
        }
    }
}

struct VisitDriver {
    let baseURL: String
    let installID: String
    let capture: FixtureCapture
    let declines: Bool
    let pollSeconds: Double
    let allowTranscriptionOff: Bool

    var client: DeviceBoundClient {
        DeviceBoundClient(baseURL: baseURL, installID: installID)
    }

    /// The app's device binding, for the shared clients that take it injected.
    var binding: @Sendable (inout URLRequest) -> Void {
        let installID = installID
        return { request in
            guard let url = request.url, let method = request.httpMethod,
                  let proof = DPoPProof.make(method: method, url: url) else { return }
            request.setValue(proof, forHTTPHeaderField: "DPoP")
            request.setValue(installID, forHTTPHeaderField: "X-Install-ID")
        }
    }

    struct Visit {
        let patientId: String
        let appointmentId: String
    }

    func run(idToken: String, refreshToken: String) async throws {
        GateSummary.log("install_id for this run: \(installID)")
        let enrollment = try await client.enroll(idToken: idToken, refreshToken: refreshToken)
        let token = enrollment.idToken
        let enrolled = GateCheck(
            name: "enrollment accepted at /native/exchange",
            ok: enrollment.exchangeStatus == 200,
            detail: "status \(enrollment.exchangeStatus), key_storage=\(enrollment.keyStorage)"
        )

        let before = try await send("GET", "/api/users/me/practice/ai-notes-consent", token)
        guard let askedBefore = before.json?["ask_clients_about_ai_notes"] as? Bool else {
            throw GateFailure(message: "reading the practice's setting: HTTP \(before.status) \(before.bodyPrefix)")
        }
        do {
            try await visit(token: token, checks: [enrolled])
        } catch {
            await restore(asked: askedBefore, token: token)
            throw error
        }
        await restore(asked: askedBefore, token: token)
    }

    /// Logged rather than thrown, so a failure here never hides the gate's.
    private func restore(asked: Bool, token: String) async {
        let put = try? await send(
            "PUT", "/api/users/me/practice/ai-notes-consent", token, json: ["ask_clients_about_ai_notes": asked]
        )
        let restored = put.map { (200 ... 299).contains($0.status) } ?? false
        GateSummary.log("\(restored ? "Restored" : "FAILED to restore") the practice's setting (asking: \(asked))")
    }

    private func visit(token: String, checks start: [GateCheck]) async throws {
        var checks = start
        let turnOn = try await send(
            "PUT", "/api/users/me/practice/ai-notes-consent", token, json: ["ask_clients_about_ai_notes": true]
        )
        let setting = try await send("GET", "/api/users/me/practice/ai-notes-consent", token)
        let settingDays = setting.json?["audio_retention_days"] as? Int
        checks.append(GateCheck(
            name: "practice asks clients",
            ok: (200 ... 299).contains(turnOn.status) && setting.json?["ask_clients_about_ai_notes"] as? Bool == true,
            detail: "PUT HTTP \(turnOn.status), retention \(settingDays.map(String.init) ?? "nil") days"
        ))

        let consent = RecordingConsentClient(baseURLString: baseURL, token: { token }, attachBinding: binding)
        let visit = try await seedVisit(token: token, patientId: nil)

        // ── The check before arming ───────────────────────────────────────
        let read = try await consent.check(appointmentId: visit.appointmentId)
        checks.append(GateCheck(
            name: "telehealth, nothing on file: ask on the recording",
            ok: read.consent == .askOnRecording,
            detail: "\(read.consent)"
        ))
        let spoken = ConsentScript.lines(retentionDays: read.audioRetentionDays).joined(separator: " ")
        let wording = settingDays.map(RetentionWording.expected(days:)) ?? "(no setting read)"
        checks.append(GateCheck(
            name: "script states the practice's audio window",
            ok: read.audioRetentionDays == settingDays && spoken.contains(wording),
            detail: "setting \(settingDays.map(String.init) ?? "nil") days, expected \"\(wording)\""
        ))

        // ── "Ask now": start, saying so, then the app's in_progress ────────
        let started = try await send(
            "POST", "/api/appointments/\(visit.appointmentId)/start-session", token,
            raw: RecordingConsentClient.startSessionBody(askingConsentOnRecording: true)
        )
        guard (200 ... 299).contains(started.status), let sessionID = started.json?["id"] as? String else {
            throw GateFailure(message: "asking start refused: HTTP \(started.status) \(started.bodyPrefix)")
        }
        let running = try await send(
            "PATCH", "/api/sessions/\(sessionID)/status", token, json: ["status": "in_progress"]
        )
        checks.append(GateCheck(
            name: "'Ask now' start accepted, session in_progress",
            ok: running.status == 200,
            detail: "session \(sessionID), in_progress HTTP \(running.status)"
        ))

        if declines {
            checks += try await decline(token: token, visit: visit, sessionID: sessionID, consent: consent)
            try GateSummary.report(checks, title: "visit (decline) gate summary", passed: "VISIT DECLINE GATE PASSED ✓")
        } else {
            checks += try await agree(token: token, visit: visit, sessionID: sessionID, consent: consent)
            try GateSummary.report(checks, title: "visit (agree) gate summary", passed: "VISIT AGREE GATE PASSED ✓")
        }
    }

    // MARK: - Wire

    func send(
        _ method: String, _ path: String, _ token: String, json: [String: Any]? = nil, raw: Data? = nil
    ) async throws -> DeviceBoundClient.Response {
        try await client.request(method, path: path, idToken: token, jsonBody: json, rawBody: raw)
    }

    /// A client (new, unless `patientId` is given) and a 50-minute telehealth
    /// appointment. The pinned test practice is shared with other runs and the
    /// server refuses an overlapping appointment, so a taken slot moves the
    /// visit on an hour, up to a day ahead.
    func seedVisit(token: String, patientId existing: String?) async throws -> Visit {
        let patientId: String
        if let existing {
            patientId = existing
        } else {
            let noise = String(UUID().uuidString.prefix(8)).lowercased()
            let patient = try await send("POST", "/api/patients", token, json: [
                "first_name": "Visit", "last_name": "Harness-\(noise)", "status": "active",
            ])
            guard let created = patient.json?["id"] as? String else {
                throw GateFailure(message: "patient create: HTTP \(patient.status) \(patient.bodyPrefix)")
            }
            patientId = created
        }
        let iso = ISO8601DateFormatter()
        for hour in 0 ..< 24 {
            let start = Date().addingTimeInterval(Double(hour) * 3600 + 5 * 60)
            let appointment = try await send("POST", "/api/appointments", token, json: [
                "patient_id": patientId,
                "title": "Visit harness",
                "start_at": iso.string(from: start),
                "end_at": iso.string(from: start.addingTimeInterval(50 * 60)),
                "duration_minutes": 50,
                "session_type": "individual",
                "video_link": "https://video.example/visit-harness",
            ])
            if appointment.status == 409 { continue }
            guard let appointmentId = appointment.json?["id"] as? String else {
                throw GateFailure(message: "appointment create: HTTP \(appointment.status) \(appointment.bodyPrefix)")
            }
            return Visit(patientId: patientId, appointmentId: appointmentId)
        }
        throw GateFailure(message: "no free telehealth slot in the next 24 hours")
    }
}

#endif
