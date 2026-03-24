import Foundation
import os

/// Strips Protected Health Information (PHI) from text before sending to the LLM.
///
/// The LLM only needs navigation structure — not clinical content.
/// This sanitizer removes patient names, phone numbers, emails, dates of birth,
/// SSNs, and ICD-10 diagnosis codes.
enum PHISanitizer {
    private static let logger = Logger(
        subsystem: AppConstants.appBundleID, category: "PHISanitizer"
    )

    /// Strips PHI from a DOM snapshot or page text.
    static func strip(from text: String, patientName: String) -> String {
        var stripped = text

        // Strip patient name and individual name parts
        stripped = stripped.replacingOccurrences(of: patientName, with: "[PATIENT]")
        for part in patientName.split(separator: " ") where part.count > 2 {
            stripped = stripped.replacingOccurrences(of: String(part), with: "[NAME]")
        }

        // Strip common PHI patterns
        for (pattern, replacement) in phiPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(stripped.startIndex..., in: stripped)
                stripped = regex.stringByReplacingMatches(
                    in: stripped, range: range, withTemplate: replacement
                )
            }
        }

        return stripped
    }

    // Phone: (xxx) xxx-xxxx, xxx-xxx-xxxx, xxx.xxx.xxxx
    // Email: user@domain.com
    // DOB: MM/DD/YYYY, MM-DD-YYYY
    // SSN: xxx-xx-xxxx
    // ICD-10: letter + 2 digits + optional .digits
    private static let phiPatterns: [(String, String)] = [
        (#"\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}"#, "[PHONE]"),
        (#"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"#, "[EMAIL]"),
        (#"\d{1,2}[/-]\d{1,2}[/-]\d{2,4}"#, "[DATE]"),
        (#"\d{3}-\d{2}-\d{4}"#, "[SSN]"),
        (#"\b[A-Z]\d{2}\.?\d{0,4}\b"#, "[DX]"),
    ]
}

/// Validates that an LLM-returned CSS selector is safe to inject into JavaScript.
///
/// Rejects selectors containing code injection patterns (javascript:, eval, fetch, etc.)
/// and selectors that are unreasonably long.
enum SelectorValidator {
    private static let logger = Logger(
        subsystem: AppConstants.appBundleID, category: "SelectorValidator"
    )

    /// Validates a selector. Throws if it contains forbidden patterns.
    static func validate(_ selector: String) throws {
        let lowered = selector.lowercased()
        for pattern in forbiddenPatterns where lowered.contains(pattern) {
            logger.error("Rejected unsafe selector: \(selector.prefix(100))")
            throw EHRNavigatorError.actionFailed(
                action: "validate",
                selector: "Selector rejected: contains forbidden pattern"
            )
        }
        if selector.count > 500 {
            throw EHRNavigatorError.actionFailed(
                action: "validate",
                selector: "Selector too long (\(selector.count) chars)"
            )
        }
    }

    private static let forbiddenPatterns = [
        "javascript:", "document.cookie", "document.location",
        "window.location", "fetch(", "xmlhttprequest",
        "eval(", "function(", "settimeout(", "setinterval(",
        "<script", "onerror=", "onload=", "onclick=",
    ]
}
