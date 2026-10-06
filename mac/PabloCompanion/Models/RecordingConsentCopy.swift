import CompanionSessionCore
import Foundation

/// The words the companion shows about a client's answer on AI-assisted notes.
/// Kept to what the web app says, so the clinician reads the same thing in
/// either app. The companion has no practice word for the people it serves, so
/// it says "client".
enum RecordingConsentCopy {
    static let declinedTitle = "AI-assisted notes declined"
    static let notAskedTitle = "No consent on file"
    static let notAskedMessage = "Ask whether the client agrees to AI-assisted notes before you record."
    static let saveFailed = "Could not save. Please try again."
    static let scriptTitle = "Consent script"
    static let scriptPrompt = "Read this aloud before you start recording."

    /// "This client declined AI-assisted notes on Oct 5, 2026." Leaves the date
    /// out when the server sent none.
    static func declined(on isoDay: String, locale: Locale = .current) -> String {
        guard !isoDay.isEmpty else { return "This client declined AI-assisted notes." }
        return "This client declined AI-assisted notes on \(RecordingConsent.displayDate(isoDay, locale: locale))."
    }
}
