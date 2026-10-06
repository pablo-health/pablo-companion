import Foundation

/// What a client's answer about AI-assisted notes means for starting a
/// recording: go ahead, ask first, or stop.
///
/// Mirrors the web app's check. Only a practice that asks its clients (the
/// practice's AI-notes consent setting) is ever anything but ``clear``. The
/// server refuses a declined client's recording regardless — this is what lets
/// the companion say so before the microphone arms, and offer a one-click
/// "agreed today" when nobody has asked yet.
public enum RecordingConsent: Equatable, Sendable {
    /// Record. The practice does not ask, or the client agreed.
    case clear
    /// The practice asks and nobody has asked this client yet.
    case notAsked
    /// The client declined. `on` is the day they answered, as `YYYY-MM-DD`.
    case declined(on: String)

    /// The backend `error.code` on a refused session start.
    public static let declinedErrorCode = "CLIENT_DECLINED_AI_NOTES"

    /// Combines the practice setting with the client's current answer.
    public static func evaluate(asksClients: Bool, current: AiConsentEntry?) -> RecordingConsent {
        guard asksClients else { return .clear }
        guard let current else { return .notAsked }
        return current.decision == AiConsentEntry.declined ? .declined(on: current.effectiveOn) : .clear
    }

    /// The answer for a start handed off from the web app. When the web app
    /// already asked "No consent on file" and the clinician chose to record
    /// anyway, asking again would be the same question twice, so a missing
    /// answer reads as clear. A decline still stops: it may have been recorded
    /// after the web app asked.
    public func handedOff(webAlreadyAsked: Bool) -> RecordingConsent {
        webAlreadyAsked && self == .notAsked ? .clear : self
    }

    /// Reads a refused session start. Returns the day the client declined when
    /// the response is the server's `403 CLIENT_DECLINED_AI_NOTES`, an empty
    /// string when the refusal carries no date, and `nil` for anything else.
    ///
    /// Body shape: `{"error": {"code", "message", "details": {"declined_on"}}}`.
    public static func declinedOn(statusCode: Int, body: Data) -> String? {
        guard statusCode == 403,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = json["error"] as? [String: Any],
              error["code"] as? String == declinedErrorCode
        else { return nil }
        let details = error["details"] as? [String: Any]
        return details?["declined_on"] as? String ?? ""
    }

    /// A `YYYY-MM-DD` day as a person reads it ("Oct 5, 2026" in en_US).
    /// Returns the input unchanged if it is not a calendar day.
    public static func displayDate(_ isoDay: String, locale: Locale = .current) -> String {
        let parts = isoDay.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return isoDay }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

/// One answer on a client's AI-notes consent record
/// (`GET /api/patients/{id}/ai-consent` → `current`).
public struct AiConsentEntry: Decodable, Equatable, Sendable {
    public static let consented = "consented"
    public static let declined = "declined"

    /// `consented` or `declined`.
    public let decision: String
    /// The day the client answered, as `YYYY-MM-DD`.
    public let effectiveOn: String

    public init(decision: String, effectiveOn: String) {
        self.decision = decision
        self.effectiveOn = effectiveOn
    }

    enum CodingKeys: String, CodingKey {
        case decision
        case effectiveOn = "effective_on"
    }
}

/// Everything the confirmation view needs to decide what to show before arming.
public struct RecordingConsentCheck: Equatable, Sendable {
    public let consent: RecordingConsent
    /// Whether the practice asks its clients. When true the read-aloud script
    /// is offered.
    public let asksClients: Bool
    /// How long the practice keeps session audio, read aloud in the script.
    public let audioRetentionDays: Int
    /// The client the answer belongs to. `nil` when the practice does not ask
    /// (the client is never looked up then).
    public let patientId: String?

    public init(consent: RecordingConsent, asksClients: Bool, audioRetentionDays: Int, patientId: String?) {
        self.consent = consent
        self.asksClients = asksClients
        self.audioRetentionDays = audioRetentionDays
        self.patientId = patientId
    }
}

/// What the clinician reads aloud before recording. Mirrors the web app's
/// script word for word so a client hears the same thing whichever app the
/// clinician starts from.
///
/// Spoken to the client, so it says "you" and needs no word for them. Four
/// things and nothing else: what is recorded, that AI drafts the note and the
/// clinician reviews it, how long the audio is kept (the practice's window),
/// and that the client can say no at any time. It states the practice's
/// chosen window and no more: whether deletion runs at the end of it belongs
/// to the deployment, so the script does not promise it.
public enum ConsentScript {
    public static func lines(retentionDays: Int) -> [String] {
        [
            "I'd like to record our session today.",
            "The recording is turned into a written transcript, and an AI tool uses it to draft my notes. "
                + "I read and correct every note myself.",
            "The audio is kept for up to \(retention(days: retentionDays)).",
            "You can say no, now or at any time.",
            "Is that all right with you?",
        ]
    }

    /// A retention window as someone would say it: "1 year", "2 years", "90 days".
    public static func retention(days: Int) -> String {
        if days > 0, days % 365 == 0 {
            let years = days / 365
            return years == 1 ? "1 year" : "\(years) years"
        }
        return days == 1 ? "1 day" : "\(days) days"
    }
}
