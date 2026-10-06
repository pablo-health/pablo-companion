import Foundation

/// What a client's answer about AI-assisted notes means for starting a
/// recording: go ahead, ask first, ask once recording starts, or stop.
///
/// Mirrors the web app's check. Only a practice that asks its clients (the
/// practice's AI-notes consent setting) is ever anything but ``clear``. The
/// server refuses a declined client's recording regardless — this is what lets
/// the companion say so before the microphone arms, and offer a one-click
/// "agreed today" when nobody has asked yet.
///
/// Nobody having asked yet splits on where the client is. In the room, the
/// clinician may ask before recording or record anyway (``notAsked``). Over
/// telehealth the client may be somewhere every party has to agree to a
/// recording, so the only way to record is to ask once recording starts, which
/// puts the answer on the recording (``askOnRecording``). The server refuses a
/// telehealth start with nothing on file unless the start says so
/// (`asking_consent_on_recording`).
public enum RecordingConsent: Equatable, Sendable {
    /// Record. The practice does not ask, or the client agreed.
    case clear
    /// The practice asks and nobody has asked this client yet (in person).
    case notAsked
    /// Telehealth, and nobody has asked this client yet: offer only asking
    /// once recording starts, or not recording. Never "record anyway".
    case askOnRecording
    /// The clinician chose to ask once recording starts: start, telling the
    /// server so, and show the script once recording is running.
    case askingOnRecording
    /// The client declined. `on` is the day they answered, as `YYYY-MM-DD`.
    case declined(on: String)

    /// The backend `error.code` on a refused session start.
    public static let declinedErrorCode = "CLIENT_DECLINED_AI_NOTES"

    /// The backend `error.code` on a telehealth start refused because nobody
    /// has asked the client and the start did not say it is asking.
    public static let consentNeededErrorCode = "CLIENT_AI_CONSENT_NEEDED"

    /// Combines the practice setting with the client's current answer and
    /// where the session is.
    public static func evaluate(
        asksClients: Bool,
        current: AiConsentEntry?,
        telehealth: Bool = false
    ) -> RecordingConsent {
        guard asksClients else { return .clear }
        guard let current else { return telehealth ? .askOnRecording : .notAsked }
        return current.decision == AiConsentEntry.declined ? .declined(on: current.effectiveOn) : .clear
    }

    /// Whether the session start tells the server the clinician is asking
    /// once recording starts.
    public var startsAskingOnRecording: Bool {
        self == .askingOnRecording
    }

    /// The answer for a start handed off from the web app.
    ///
    /// `webAlreadyAsked`: the web app already asked "No consent on file" and
    /// the clinician chose to record anyway. Asking again would be the same
    /// question twice, so a missing in-person answer reads as clear. It never
    /// clears a telehealth start: the server would refuse it.
    ///
    /// `webAskingOnRecording`: for a telehealth start with nothing on file,
    /// the web app already offered "Ask now" and the clinician took it, so the
    /// companion starts asking on the recording without offering it again.
    ///
    /// A decline still stops either way: it may have been recorded after the
    /// web app asked.
    public func handedOff(webAlreadyAsked: Bool, webAskingOnRecording: Bool = false) -> RecordingConsent {
        switch self {
        case .notAsked where webAlreadyAsked: .clear
        case .askOnRecording where webAskingOnRecording: .askingOnRecording
        default: self
        }
    }

    /// Whether a refused session start is the server's
    /// `403 CLIENT_AI_CONSENT_NEEDED`: a telehealth client nobody has asked.
    public static func isConsentNeeded(statusCode: Int, body: Data) -> Bool {
        guard statusCode == 403,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = json["error"] as? [String: Any]
        else { return false }
        return error["code"] as? String == consentNeededErrorCode
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

/// Whether a visit is telehealth: a video service, a video link, or a
/// telehealth place of service ("02", "10"). Mirrors `is_telehealth` on the
/// server, which is what decides.
public enum Telehealth {
    /// Place-of-service codes for a visit held by video or phone.
    public static let places: Set<String> = ["02", "10"]

    public static func isTelehealth(provider: String?, videoLink: String?, placeOfService: String?) -> Bool {
        if let provider, !provider.isEmpty { return true }
        if let videoLink, !videoLink.isEmpty { return true }
        return placeOfService.map(places.contains) ?? false
    }

    /// The same answer as a modality.
    public static func modality(provider: String?, videoLink: String?, placeOfService: String?) -> AiConsentModality {
        isTelehealth(provider: provider, videoLink: videoLink, placeOfService: placeOfService) ? .telehealth : .inPerson
    }
}

/// Where a client's answer was given (`modality` on the consent record).
public enum AiConsentModality: String, Sendable, CaseIterable {
    case inPerson = "in_person"
    case telehealth
}

/// Who gave the answer: the client, or a parent or guardian for them
/// (`consented_by` on the consent record).
public enum AiConsentGiver: String, Sendable, CaseIterable, Identifiable {
    case client
    case parent
    case guardian

    public var id: String {
        rawValue
    }

    /// As a person reads it. The companion has no practice word for the
    /// people it serves, so it says "Client".
    public var word: String {
        switch self {
        case .client: "Client"
        case .parent: "Parent"
        case .guardian: "Guardian"
        }
    }
}

/// One answer as the clinician records it
/// (`POST /api/patients/{id}/ai-consent`). No date is sent: the server dates it
/// on the clinician's own calendar day, so an evening entry is not dated
/// tomorrow.
public struct AiConsentAnswer: Equatable, Sendable {
    /// The longest place the server keeps; a place, not a note.
    public static let locationMaxLength = 200

    /// `consented` or `declined`.
    public let decision: String
    public let modality: AiConsentModality
    public let consentedBy: AiConsentGiver
    /// Where the client said they were, in their words. Telehealth only.
    public let clientStatedLocation: String?

    public init(
        decision: String,
        modality: AiConsentModality,
        consentedBy: AiConsentGiver,
        clientStatedLocation: String? = nil
    ) {
        self.decision = decision
        self.modality = modality
        self.consentedBy = consentedBy
        self.clientStatedLocation = clientStatedLocation
    }

    /// "Client agreed today" in the room, as the web app records it.
    public static func agreedInPerson(by giver: AiConsentGiver) -> AiConsentAnswer {
        AiConsentAnswer(decision: AiConsentEntry.consented, modality: .inPerson, consentedBy: giver)
    }

    /// The request body. A place is sent only for telehealth, trimmed, and
    /// only when one was given.
    public var body: [String: String] {
        var body = [
            "decision": decision,
            "modality": modality.rawValue,
            "consented_by": consentedBy.rawValue,
        ]
        let place = (clientStatedLocation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if modality == .telehealth, !place.isEmpty {
            body["client_stated_location"] = String(place.prefix(Self.locationMaxLength))
        }
        return body
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

/// What the clinician reads aloud once recording has started, so the client's
/// answer is on the recording itself. Mirrors the web app's script word for
/// word so a client hears the same thing whichever app the clinician starts
/// from.
///
/// Spoken to the client, so it says "you" and needs no word for them. Four
/// things and nothing else: what is recorded, that AI drafts the note and the
/// clinician reviews it, how long the audio is kept (the practice's window),
/// and that the client can say no at any time.
///
/// A window of 0 days means the audio is deleted once the note is signed.
/// Signing enforces that, so the script says it plainly. For a number of days
/// it states the practice's window and no more: whether deletion runs at the
/// end of it belongs to the deployment, so the script does not promise it.
public enum ConsentScript {
    /// `audio_retention_days` for "deleted once the note is signed".
    public static let deletedOnSigning = 0

    public static func lines(retentionDays: Int) -> [String] {
        [
            "I've started recording our session.",
            "The recording is turned into a written transcript, and an AI tool uses it to draft my notes. "
                + "I read and correct every note myself.",
            retentionDays == deletedOnSigning
                ? "The audio is deleted once your note is signed."
                : "The audio is kept for up to \(retention(days: retentionDays)).",
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
