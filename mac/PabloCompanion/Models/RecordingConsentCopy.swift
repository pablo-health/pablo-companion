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
    /// Telehealth with nothing on file: the only way to record is to ask once
    /// recording starts, so the answer is on the recording.
    static let askOnRecordingMessage =
        "For a telehealth session, ask once recording starts, so the client's answer is on the recording."
    static let askNow = "Ask now"
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

    /// "Client agreed today", "Parent agreed today".
    static func agreedToday(by giver: AiConsentGiver) -> String {
        "\(giver.word) agreed today"
    }

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
