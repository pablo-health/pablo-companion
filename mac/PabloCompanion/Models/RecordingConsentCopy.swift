import CompanionSessionCore
import Foundation

/// The words the companion shows about a client's answer on AI-assisted notes.
/// Kept to what the web app says, so the clinician reads the same thing in
/// either app. The companion has no practice word for the people it serves, so
/// it says "client".
enum RecordingConsentCopy {
    static let declinedTitle = "AI-assisted notes declined"
    static let notAskedTitle = "No consent on file"
    /// Nothing on file, in person or over telehealth: the only way to record is
    /// to ask once recording starts, so the answer is on the recording. The
    /// script is shown then, not before; its first line says recording has
    /// started.
    static let askOnRecordingMessage = "You'll see what to read aloud once recording starts."
    /// A telehealth start the server refused for the same reason, wherever it
    /// shows without the "Start recording and ask" button beside it.
    static let consentNeededError = "Ask about AI-assisted notes once recording starts."
    static let startAndAsk = "Start recording and ask"
    static let dontRecord = "Don't record"
    static let answeredBy = "Answered by"
    static let saveFailed = "Could not save. Please try again."
    static let scriptTitle = "Consent script"
    static let scriptPrompt = "Start recording, then read this aloud so the answer is on the recording."

    /// The panel shown once recording has started, for a client asked on it.
    static let askingTitle = "Asking about AI-assisted notes"
    static let askingPrompt = "Recording has started. Read this aloud so the answer is on the recording."
    static let locationLabel = "Where the client said they were"
    static let recordOnChart = "Record the client's answer on their chart."
    /// After a decline on the recording: capture stopped and the audio deleted.
    static let recordingDeleted = "Recording stopped and deleted. Write this note yourself."

    /// "Client agreed", "Guardian declined".
    static func answered(_ decision: String, by giver: AiConsentGiver) -> String {
        "\(giver.word) \(decision == AiConsentEntry.declined ? "declined" : "agreed")"
    }

    /// "This client declined AI-assisted notes on Oct 5, 2026." Leaves the date
    /// out when the server sent none.
    static func declined(on isoDay: String, locale: Locale = .current) -> String {
        guard !isoDay.isEmpty else { return "This client declined AI-assisted notes." }
        return "This client declined AI-assisted notes on \(RecordingConsent.displayDate(isoDay, locale: locale))."
    }
}
