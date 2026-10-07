#if canImport(CompanionAuthCore)

import Foundation

/// Polls a session to its note and gates on a four-section SOAP with
/// audio-derived content. Shared by the `record` and `visit` scenarios.
struct SoapGate {
    let client: DeviceBoundClient
    let idToken: String
    let pollSeconds: Double

    static let soapSections = ["subjective", "objective", "assessment", "plan"]

    /// Whether an upload refused with 501 (transcription turned off on this
    /// backend) may pass. Off unless `RECORD_ALLOW_TRANSCRIPTION_OFF=1`: a
    /// deployment with transcription off cannot produce the note this gate
    /// exists to prove, so on dev or prod a 501 is a failure, not a skip. Only
    /// a stack with no ASR at all (a local one) should set it.
    static func allowsTranscriptionOff(env: [String: String]) -> Bool {
        env["RECORD_ALLOW_TRANSCRIPTION_OFF"] == "1"
    }

    static func transcriptionOffCheck(allowed: Bool) -> GateCheck {
        GateCheck(
            name: "upload path reached (transcription off, 501)",
            ok: allowed,
            detail: allowed
                ? "status 501; allowed by RECORD_ALLOW_TRANSCRIPTION_OFF=1"
                : "status 501: transcription is off on this backend, so no note can be proven"
        )
    }

    func poll(sessionID: String) async throws -> GateCheck {
        let deadline = Date().addingTimeInterval(pollSeconds)
        var lastStatus = "transcribing"
        while Date() < deadline {
            let poll = try await client.request("GET", path: "/api/sessions/\(sessionID)", idToken: idToken)
            guard poll.status == 200 else {
                throw GateFailure(message: "poll failed: \(poll.status) \(poll.bodyPrefix)")
            }
            lastStatus = (poll.json?["status"] as? String) ?? lastStatus
            if lastStatus == "failed" {
                return GateCheck(name: "SOAP generated", ok: false, detail: "session status 'failed'")
            }
            if lastStatus == "pending_review" {
                let note = poll.json?["note"] as? [String: Any]
                dumpNote(note)
                return evaluate(note)
            }
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        return GateCheck(name: "SOAP generated", ok: false, detail: "deadline hit (last status '\(lastStatus)')")
    }

    /// Logs the generated SOAP note so a run can be eyeballed against the fixture
    /// audio. The session is always one the harness itself created in the pinned
    /// test tenant from synthetic `say` audio — never a real patient's note.
    private func dumpNote(_ note: [String: Any]?) {
        guard let note else {
            GateSummary.log("generated note: nil")
            return
        }
        let content = note["content"] ?? [:]
        guard let data = try? JSONSerialization.data(
            withJSONObject: content, options: [.prettyPrinted, .sortedKeys]
        ), let text = String(data: data, encoding: .utf8) else { return }
        GateSummary.log("""
        ───── generated SOAP (note_type=\(note["note_type"] ?? "?")) ─────
        \(text)
        ──────────────────────────────────────
        """)
    }

    /// Ports `sectionHasContent` from `asr-integration.spec.ts`: the embedded note
    /// is a 4-section SOAP with at least one section populated.
    private func evaluate(_ note: [String: Any]?) -> GateCheck {
        guard let note else { return GateCheck(name: "SOAP generated", ok: false, detail: "no note on session") }
        guard (note["note_type"] as? String) == "soap" else {
            return GateCheck(name: "SOAP generated", ok: false, detail: "note_type \(note["note_type"] ?? "nil")")
        }
        let content = note["content"] as? [String: Any] ?? [:]
        let present = Self.soapSections.filter { content[$0] != nil }
        let populated = Self.soapSections.filter { sectionHasContent(content[$0] as? [String: Any]) }
        return GateCheck(
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
}

#endif
