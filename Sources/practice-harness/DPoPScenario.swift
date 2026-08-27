#if canImport(CompanionAuthCore)

import CompanionAuthCore
import Foundation

/// `PRACTICE_SCENARIO=dpop` — drives the REAL device-binding stack against a
/// deployed backend, end to end:
///
///   sign in (pinned test user) → POST /api/auth/native/code →
///   POST /api/auth/native/exchange carrying a `DeviceEnrollment` payload built
///   from the actual `DeviceKey` (Secure Enclave on real hardware, software
///   P-256 on CI VMs) → signed request with `DPoP` + `X-Install-ID` headers
///   produced by the actual `DPoPProof` → enforcement negatives (replayed
///   proof, install id without proof) → launch-intent issue + signed redeem.
///
/// Every positive step uses `CompanionAuthCore` exactly as the shipping app
/// does — JWS layout, htu canonicalization, JWK encoding, enrollment schema —
/// so a drift between the client crypto and `backend/app/middleware/dpop.py`
/// fails here before it fails for an enrolled user.
///
/// Environment:
///   PRACTICE_BASE_URL            backend base URL
///   FB_API_KEY + FB_* creds      same sign-in plumbing as the practice scenario
///   DPOP_EXPECT_ENFORCED         "0" to skip the 401 negatives while
///                                ENABLE_DPOP_VALIDATION is still off (default "1")
///   DPOP_EXPECT_LAUNCH_INTENT    "0" to skip the launch-intent leg while
///                                ENABLE_LAUNCH_INTENT is still off (default "1")
enum DPoPScenario {
    static func run(env: [String: String]) async {
        let baseURL = env["PRACTICE_BASE_URL"] ?? "https://app.pablo.health"
        let expectEnforced = env["DPOP_EXPECT_ENFORCED"] != "0"
        let expectLaunch = env["DPOP_EXPECT_LAUNCH_INTENT"] != "0"

        // Namespace the harness's keychain rows away from any real install on
        // the same machine; no access group — an unsigned CLI has no keychain
        // entitlements (see AuthCoreConfig).
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
            PracticeHarness.fail("FB_API_KEY is required for the dpop scenario.")
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
                expectEnforced: expectEnforced,
                expectLaunch: expectLaunch
            ).run()
        } catch {
            PracticeHarness.fail("dpop scenario failed: \(error.localizedDescription)")
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}

private struct Driver {
    let baseURL: String
    let idToken: String
    let refreshToken: String
    let expectEnforced: Bool
    let expectLaunch: Bool

    /// The redirect URI only has to be an allowed native scheme — the harness
    /// never opens it; the code comes back in the POST body.
    private let redirectURI = "pablohealth://auth/callback"

    private struct Check {
        let name: String
        let ok: Bool
        let detail: String
    }

    func run() async throws {
        var checks: [Check] = []
        let installID = UUID().uuidString.lowercased()
        let client = DeviceBoundClient(baseURL: baseURL, installID: installID)
        log("install_id for this run: \(installID)")

        // ── 1. Enrollment via the real OAuth code exchange ──────────────
        let enrollment = try await client.enroll(
            idToken: idToken,
            refreshToken: refreshToken,
            redirectURI: redirectURI
        )
        let idToken = enrollment.idToken
        log("Enrollment payload built (key_storage=\(enrollment.keyStorage))")
        checks.append(Check(
            name: "enrollment accepted at /native/exchange",
            ok: enrollment.exchangeStatus == 200,
            detail: "status \(enrollment.exchangeStatus)"
        ))

        // ── 2. Signed request with the real proof ───────────────────────
        let devices = try await client.request(
            "GET", path: "/api/users/me/devices", idToken: idToken
        )
        let listed = (try? JSONSerialization.jsonObject(with: devices.body)) as? [[String: Any]]
        let found = listed?.contains { $0["install_id"] as? String == installID } ?? false
        checks.append(Check(
            name: "signed GET /users/me/devices",
            ok: devices.status == 200,
            detail: "status \(devices.status)"
        ))
        checks.append(Check(
            name: "enrolled install listed",
            ok: found,
            detail: found ? "install_id present" : "install_id missing from \(listed?.count ?? 0) devices"
        ))

        // ── 3. Enforcement negatives ─────────────────────────────────────
        if expectEnforced {
            guard let url = URL(string: baseURL + "/api/users/me/devices"),
                  let proof = DPoPProof.make(method: "GET", url: url)
            else { throw DriverError("could not build replay proof") }

            let first = try await client.request(
                "GET", path: "/api/users/me/devices", idToken: idToken,
                presetProof: proof
            )
            let replayed = try await client.request(
                "GET", path: "/api/users/me/devices", idToken: idToken,
                presetProof: proof
            )
            checks.append(Check(
                name: "replayed jti rejected",
                ok: first.status == 200 && replayed.status == 401,
                detail: "first \(first.status), replay \(replayed.status)"
            ))

            let bare = try await client.request(
                "GET", path: "/api/users/me/devices", idToken: idToken,
                omitProof: true
            )
            checks.append(Check(
                name: "install id without proof rejected",
                ok: bare.status == 401,
                detail: "status \(bare.status)"
            ))
        } else {
            log("DPOP_EXPECT_ENFORCED=0 — skipping the 401 negatives (middleware dark)")
        }

        // ── 4. Launch intent: issue + signed redeem, single-use ──────────
        if expectLaunch {
            let noise = String(UUID().uuidString.prefix(8)).lowercased()
            let patient = try await client.request(
                "POST", path: "/api/patients", idToken: idToken,
                jsonBody: ["first_name": "E2E", "last_name": "DPoP-\(noise)", "status": "active"]
            )
            guard patient.status == 201 || patient.status == 200,
                  let patientID = patient.json?["id"] as? String
            else { throw DriverError("patient create failed: \(patient.status) \(patient.bodyPrefix)") }

            let start = Date().addingTimeInterval(3600)
            let appt = try await client.request(
                "POST", path: "/api/appointments", idToken: idToken,
                jsonBody: [
                    "patient_id": patientID,
                    "title": "E2E dpop launch",
                    "start_at": client.iso8601(start),
                    "end_at": client.iso8601(start.addingTimeInterval(50 * 60)),
                    "duration_minutes": 50,
                    "session_type": "individual",
                ]
            )
            guard appt.status == 201 || appt.status == 200,
                  let appointmentID = appt.json?["id"] as? String
            else { throw DriverError("appointment create failed: \(appt.status) \(appt.bodyPrefix)") }

            let intent = try await client.request(
                "POST", path: "/api/launch/intent", idToken: idToken,
                jsonBody: ["appointment_id": appointmentID]
            )
            let intentID = intent.json?["intent_id"] as? String
            checks.append(Check(
                name: "launch intent issued",
                ok: intent.status == 200 && intentID != nil,
                detail: "status \(intent.status)"
            ))

            if let intentID {
                let redeem = try await client.request(
                    "POST", path: "/api/launch/redeem", idToken: idToken,
                    jsonBody: ["intent_id": intentID]
                )
                let boundAppointment = redeem.json?["appointment_id"] as? String
                checks.append(Check(
                    name: "signed redeem returns the appointment",
                    ok: redeem.status == 200 && boundAppointment == appointmentID,
                    detail: "status \(redeem.status), appointment \(boundAppointment ?? "nil")"
                ))

                let again = try await client.request(
                    "POST", path: "/api/launch/redeem", idToken: idToken,
                    jsonBody: ["intent_id": intentID]
                )
                checks.append(Check(
                    name: "second redeem is 410 (single-use)",
                    ok: again.status == 410,
                    detail: "status \(again.status)"
                ))
            }
        } else {
            log("DPOP_EXPECT_LAUNCH_INTENT=0 — skipping the launch-intent leg (router not mounted)")
        }

        try summarize(checks)
    }

    private func summarize(_ checks: [Check]) throws {
        let pad = checks.map(\.name.count).max() ?? 0
        let lines = checks
            .map {
                "  [\($0.ok ? "PASS" : "FAIL")] \($0.name.padding(toLength: pad, withPad: " ", startingAt: 0))  \($0.detail)"
            }
            .joined(separator: "\n")
        log("""
        ───── dpop gate summary ─────
        \(lines)
        ─────────────────────────────
        """)
        let failed = checks.filter { !$0.ok }.map(\.name)
        if !failed.isEmpty {
            throw DriverError("Gate FAILED: \(failed.joined(separator: ", "))")
        }
        log("DPOP GATE PASSED ✓")
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}

private struct DriverError: LocalizedError {
    let message: String
    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

#endif
