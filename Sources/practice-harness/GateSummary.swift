import Foundation

/// One pass/fail line in a scenario's gate.
struct GateCheck {
    let name: String
    let ok: Bool
    let detail: String
}

struct GateFailure: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

enum GateSummary {
    /// Logs every check as a PASS/FAIL table and throws when any failed.
    static func report(_ checks: [GateCheck], title: String, passed: String) throws {
        let pad = checks.map(\.name.count).max() ?? 0
        let lines = checks
            .map { check in
                let name = check.name.padding(toLength: pad, withPad: " ", startingAt: 0)
                return "  [\(check.ok ? "PASS" : "FAIL")] \(name)  \(check.detail)"
            }
            .joined(separator: "\n")
        log("""
        ───── \(title) ─────
        \(lines)
        ───────────────────────────────
        """)
        let failed = checks.filter { !$0.ok }.map(\.name)
        if !failed.isEmpty {
            throw GateFailure(message: "Gate FAILED: \(failed.joined(separator: ", "))")
        }
        log(passed)
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}

/// What the read-aloud script must say about how long the practice keeps
/// audio, worked out from the practice's setting rather than from
/// `ConsentScript` itself — so a script that ignored the window, or said the
/// wrong thing for it, fails rather than agreeing with itself.
enum RetentionWording {
    static func expected(days: Int) -> String {
        if days == 0 {
            return "deleted once your note is signed"
        }
        if days.isMultiple(of: 365) {
            let years = days / 365
            return "kept for up to \(years) year\(years == 1 ? "" : "s")"
        }
        return "kept for up to \(days) day\(days == 1 ? "" : "s")"
    }
}
