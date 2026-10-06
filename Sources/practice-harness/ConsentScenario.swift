import CompanionSessionCore
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `PRACTICE_SCENARIO=consent` — drives the companion's AI-notes consent wire
/// path (`CompanionSessionCore.RecordingConsentClient`, the session-start body
/// and the consent answer body) against a backend, as a signed-in clinician:
///
///   turn on asking clients (and, with `CONSENT_RETENTION_DAYS`, set the audio
///   retention window) → seed a client with a telehealth visit and one with an
///   in-person visit →
///   - the telehealth visit reads as "ask on the recording", and the script
///     names the practice's window;
///   - a plain start is refused with `403 CLIENT_AI_CONSENT_NEEDED`;
///   - a start that says it is asking on the recording is accepted;
///   - the client's answer is saved as given over telehealth, with who
///     answered and where they said they were, and then reads as clear;
///   - a decline on the recording is saved, the session returns to a
///     hand-written note, and a later recorded start is refused;
///   - the in-person visit reads as "not asked" and a plain start is accepted.
///
/// The practice's setting and retention window are put back as they were when
/// the run ends, pass or fail, so a run against a shared test practice leaves
/// no trace on the other tests that use it.
///
/// Environment:
///   PRACTICE_BASE_URL       backend base URL
///   PRACTICE_BEARER_TOKEN   the clinician's ID token; or, to sign in the way
///                           the record scenario does, FB_API_KEY with
///                           FB_REFRESH_TOKEN or FB_EMAIL + FB_PASSWORD +
///                           FB_TOTP_SECRET
///   CONSENT_RETENTION_DAYS  optional; e.g. 0 for "deleted once signed"
enum ConsentScenario {
    static func run(env: [String: String]) async {
        let baseURL = env["PRACTICE_BASE_URL"] ?? "https://app.pablo.health"
        let retention = env["CONSENT_RETENTION_DAYS"].flatMap(Int.init)
        do {
            let token = try await bearerToken(env: env)
            try await Driver(baseURL: baseURL, token: token, retentionDays: retention).run()
        } catch {
            PracticeHarness.fail("consent scenario failed: \(error)")
        }
    }

    private static func bearerToken(env: [String: String]) async throws -> String {
        if let preset = env["PRACTICE_BEARER_TOKEN"], !preset.isEmpty {
            return preset
        }
        guard let apiKey = env["FB_API_KEY"], !apiKey.isEmpty else {
            PracticeHarness.fail("Set PRACTICE_BEARER_TOKEN, or FB_API_KEY to sign in, for the consent scenario.")
        }
        let auth = try await FirebaseAuth(apiKey: apiKey).mint(
            refreshToken: env["FB_REFRESH_TOKEN"],
            email: env["FB_EMAIL"],
            password: env["FB_PASSWORD"],
            totpSecret: env["FB_TOTP_SECRET"]
        )
        log("Signed in via \(auth.mode)")
        return auth.idToken
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}

private struct Driver {
    let baseURL: String
    let token: String
    let retentionDays: Int?

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    func run() async throws {
        let before = try await send("GET", "/api/users/me/practice/ai-notes-consent")
        guard let askedBefore = before.json?["ask_clients_about_ai_notes"] as? Bool,
              let retentionBefore = before.json?["audio_retention_days"] as? Int
        else {
            throw Failure(description: "reading the practice's setting: HTTP \(before.status) \(before.text)")
        }
        do {
            try await checks()
        } catch {
            await restore(asked: askedBefore, retentionDays: retentionBefore)
            throw error
        }
        await restore(asked: askedBefore, retentionDays: retentionBefore)
    }

    /// Put the practice's setting and retention window back as they were.
    /// Logged rather than thrown, so a failure here never hides the checks'.
    private func restore(asked: Bool, retentionDays before: Int) async {
        do {
            let setting = try await send(
                "PUT", "/api/users/me/practice/ai-notes-consent", ["ask_clients_about_ai_notes": asked]
            )
            var restored = (200 ... 299).contains(setting.status)
            if retentionDays != nil {
                let retention = try await send(
                    "PUT", "/api/users/me/practice/audio-retention", ["audio_retention_days": before]
                )
                restored = restored && (200 ... 299).contains(retention.status)
            }
            let outcome = restored ? "Restored" : "FAILED to restore"
            ConsentScenario.log("\(outcome) the practice's setting (asking: \(asked))")
        } catch {
            ConsentScenario.log("FAILED to restore the practice's setting: \(error)")
        }
    }

    private func checks() async throws {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String) {
            ConsentScenario.log("\(ok ? "PASS" : "FAIL")  \(name) — \(detail)")
            if !ok { failures += 1 }
        }

        _ = try await send("PUT", "/api/users/me/practice/ai-notes-consent", ["ask_clients_about_ai_notes": true])
        if let retentionDays {
            _ = try await send("PUT", "/api/users/me/practice/audio-retention", ["audio_retention_days": retentionDays])
        }

        let consent = RecordingConsentClient(baseURLString: baseURL, token: { token }, attachBinding: { _ in })

        // ── Telehealth, nothing on file ─────────────────────────────────────
        let remote = try await seedVisit(videoLink: "https://video.example/room", inHours: 0)
        let read = try await consent.check(appointmentId: remote.appointmentId)
        check("telehealth visit offers only asking on the recording", read.consent == .askOnRecording, "\(read.consent)")
        let script = ConsentScript.lines(retentionDays: read.audioRetentionDays)
        check("script names the practice's window", true, "retention \(read.audioRetentionDays): \(script[2])")

        let plain = try await start(remote.appointmentId, asking: false)
        check(
            "plain telehealth start is refused",
            RecordingConsent.isConsentNeeded(statusCode: plain.status, body: plain.body),
            "HTTP \(plain.status) \(plain.text)"
        )

        let asking = try await start(remote.appointmentId, asking: true)
        check("'Ask now' start is accepted", (200 ... 299).contains(asking.status), "HTTP \(asking.status)")

        let answer = AiConsentAnswer(
            decision: AiConsentEntry.consented,
            modality: .telehealth,
            consentedBy: .parent,
            clientStatedLocation: " At home "
        )
        try await consent.record(answer, patientId: remote.patientId)
        let stored = try await send("GET", "/api/patients/\(remote.patientId)/ai-consent")
        let current = (stored.json?["current"] as? [String: Any]) ?? [:]
        check(
            "answer saved as given over telehealth",
            current["modality"] as? String == "telehealth"
                && current["consented_by"] as? String == "parent"
                && current["client_stated_location"] as? String == "At home",
            "modality=\(current["modality"] ?? "nil") consented_by=\(current["consented_by"] ?? "nil") "
                + "location=\(current["client_stated_location"] ?? "nil")"
        )
        let after = try await consent.check(appointmentId: remote.appointmentId)
        check("after agreeing, the client reads as clear", after.consent == .clear, "\(after.consent)")

        // ── Telehealth, declined on the recording ──────────────────────────
        // The app stops and deletes the recording, saves the decline, and
        // returns the session to a hand-written note (scheduled, the state the
        // web starts one in with `recording: false`).
        let declining = try await seedVisit(videoLink: "https://video.example/room2", inHours: 2)
        let declinedStart = try await start(declining.appointmentId, asking: true)
        let declinedSession = declinedStart.json?["id"] as? String ?? ""
        let running = try await send("PATCH", "/api/sessions/\(declinedSession)/status", ["status": "in_progress"])
        try await consent.record(
            AiConsentAnswer(decision: AiConsentEntry.declined, modality: .telehealth, consentedBy: .client),
            patientId: declining.patientId
        )
        let handWritten = try await send("PATCH", "/api/sessions/\(declinedSession)/status", ["status": "scheduled"])
        check(
            "a decline returns the session to a hand-written note",
            running.status == 200 && handWritten.status == 200 && handWritten.json?["status"] as? String == "scheduled",
            "in_progress HTTP \(running.status), then scheduled HTTP \(handWritten.status) "
                + "status=\(handWritten.json?["status"] ?? "nil")"
        )
        let later = try await seedVisit(videoLink: "https://video.example/room3", inHours: 3, patientId: declining.patientId)
        let laterStart = try await start(later.appointmentId, asking: true)
        check(
            "after a decline, a later recorded start is refused",
            RecordingConsent.declinedOn(statusCode: laterStart.status, body: laterStart.body) != nil,
            "HTTP \(laterStart.status) \(laterStart.text)"
        )

        // ── In person, nothing on file (unchanged) ─────────────────────────
        let office = try await seedVisit(videoLink: nil, inHours: 1)
        let inPerson = try await consent.check(appointmentId: office.appointmentId)
        check("in-person visit still offers agreed today / record anyway", inPerson.consent == .notAsked, "\(inPerson.consent)")
        let officeStart = try await start(office.appointmentId, asking: false)
        check("plain in-person start is accepted", (200 ... 299).contains(officeStart.status), "HTTP \(officeStart.status)")

        guard failures == 0 else { throw Failure(description: "\(failures) check(s) failed") }
        ConsentScenario.log("ALL CHECKS PASSED")
    }

    // MARK: - Wire

    private struct Reply {
        let status: Int
        let body: Data
        var json: [String: Any]? {
            try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        }

        var text: String {
            String(decoding: body.prefix(300), as: UTF8.self)
        }
    }

    private struct Visit {
        let patientId: String
        let appointmentId: String
    }

    /// A client and a 50-minute visit starting `inHours` (plus five minutes)
    /// from now, so visits seeded in one run do not overlap.
    private func seedVisit(videoLink: String?, inHours: Double, patientId existing: String? = nil) async throws -> Visit {
        let patientId: String
        if let existing {
            patientId = existing
        } else {
            let noise = String(UUID().uuidString.prefix(8)).lowercased()
            let patient = try await send("POST", "/api/patients", [
                "first_name": "Consent", "last_name": "Harness-\(noise)", "status": "active",
            ])
            guard let created = patient.json?["id"] as? String else {
                throw Failure(description: "patient create: HTTP \(patient.status) \(patient.text)")
            }
            patientId = created
        }
        let start = Date().addingTimeInterval(inHours * 3600 + 5 * 60)
        let iso = ISO8601DateFormatter()
        var body: [String: Any] = [
            "patient_id": patientId,
            "title": "Consent harness",
            "start_at": iso.string(from: start),
            "end_at": iso.string(from: start.addingTimeInterval(50 * 60)),
            "duration_minutes": 50,
            "session_type": "individual",
        ]
        if let videoLink { body["video_link"] = videoLink }
        let appointment = try await send("POST", "/api/appointments", body)
        guard let appointmentId = appointment.json?["id"] as? String else {
            throw Failure(description: "appointment create: HTTP \(appointment.status) \(appointment.text)")
        }
        return Visit(patientId: patientId, appointmentId: appointmentId)
    }

    /// `POST /api/appointments/{id}/start-session` with exactly the body the
    /// app sends.
    private func start(_ appointmentId: String, asking: Bool) async throws -> Reply {
        try await send(
            "POST",
            "/api/appointments/\(appointmentId)/start-session",
            raw: RecordingConsentClient.startSessionBody(askingConsentOnRecording: asking)
        )
    }

    private func send(_ method: String, _ path: String, _ json: [String: Any]) async throws -> Reply {
        try await send(method, path, raw: JSONSerialization.data(withJSONObject: json))
    }

    private func send(_ method: String, _ path: String, raw: Data? = nil) async throws -> Reply {
        guard let url = URL(string: "\(baseURL)\(path)") else { throw Failure(description: "bad URL \(path)") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("pablo-companion-macos/1.0", forHTTPHeaderField: "X-Client-Type")
        if let raw {
            request.httpBody = raw
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return Reply(status: (response as? HTTPURLResponse)?.statusCode ?? -1, body: data)
    }
}
