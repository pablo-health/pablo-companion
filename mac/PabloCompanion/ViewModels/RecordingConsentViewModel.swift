import CompanionSessionCore
import Foundation
import os

/// The client's answer about AI-assisted notes, read before the microphone arms.
///
/// When the practice asks its clients, a client who declined stops the start.
/// A client nobody has asked yet, in person or over telehealth, gets two
/// choices: ask once recording starts ("Ask now"), or don't record. The answer
/// is then given on the recording and saved from the panel shown there. With
/// the setting off this is always ``RecordingConsent/clear`` and no prompt
/// appears.
///
/// A failed read does not block the start: the server refuses a declined
/// client's recording, and a telehealth client nobody has asked, on its own.
/// ``showRefusal(declinedOn:)`` and ``showConsentNeeded()`` turn those
/// refusals into the same prompts.
@MainActor
@Observable
final class RecordingConsentViewModel {
    enum Phase: Equatable {
        /// Nothing read (or the read failed). Behaves as clear.
        case idle
        case checking
        case ready(RecordingConsentCheck)
    }

    private(set) var phase: Phase = .idle

    /// Bumped on every check and reset, so a slow read for a start the
    /// clinician already cancelled cannot overwrite a newer one.
    private var generation = 0
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "RecordingConsent")

    /// What the confirmation view should ask about.
    var consent: RecordingConsent {
        if case let .ready(check) = phase { return check.consent }
        return .clear
    }

    var isChecking: Bool {
        phase == .checking
    }

    /// The practice's audio retention window when it asks its clients — the
    /// cue to offer the read-aloud script. `nil` hides the script.
    var scriptRetentionDays: Int? {
        guard case let .ready(check) = phase, check.asksClients else { return nil }
        return check.audioRetentionDays
    }

    /// The client the answer belongs to, for the answer given on the recording.
    var patientId: String? {
        if case let .ready(check) = phase { return check.patientId }
        return nil
    }

    /// Reads the setting and the client's answer. Never throws: a failure is
    /// logged and treated as clear, because the server still refuses what the
    /// answer does not allow.
    ///
    /// `modality`: where the session is, when the caller knows.
    /// `webAlreadyAsked` / `webAskingOnRecording`: what the web start already
    /// chose; see ``RecordingConsent/handedOff(webAlreadyAsked:webAskingOnRecording:)``.
    @discardableResult
    func check(
        appointmentId: String,
        patientId: String?,
        modality: AiConsentModality? = nil,
        webAlreadyAsked: Bool = false,
        webAskingOnRecording: Bool = false,
        service: RecordingConsentService
    ) async -> RecordingConsent {
        generation += 1
        let current = generation
        phase = .checking
        do {
            let read = try await service.checkRecordingConsent(
                appointmentId: appointmentId,
                patientId: patientId,
                modality: modality
            )
            guard current == generation else { return .clear }
            let consent = read.consent.handedOff(
                webAlreadyAsked: webAlreadyAsked,
                webAskingOnRecording: webAskingOnRecording
            )
            phase = .ready(replacing(read, with: consent))
            return consent
        } catch {
            guard current == generation else { return .clear }
            logger.error("Consent check failed: \(error.localizedDescription)")
            phase = .idle
            return .clear
        }
    }

    /// The server refused the start because the client declined. Shows the
    /// declined message in place of a generic error.
    func showRefusal(declinedOn: String) {
        showServerAnswer(.declined(on: declinedOn))
    }

    /// The server refused a telehealth start because nobody has asked the
    /// client (an older read, or the answer was removed after it). Offers
    /// "Ask now" or "Don't record" in place of a generic error.
    func showConsentNeeded() {
        showServerAnswer(.askOnRecording(.telehealth))
    }

    /// "Ask now": the start tells the server the clinician is asking once
    /// recording starts, and the script follows once recording is running.
    func askNow() {
        guard case let .ready(check) = phase, case let .askOnRecording(modality) = check.consent else { return }
        phase = .ready(replacing(check, with: .askingOnRecording(modality)))
    }

    func reset() {
        generation += 1
        phase = .idle
    }

    private func showServerAnswer(_ consent: RecordingConsent) {
        generation += 1
        let previous: RecordingConsentCheck? = if case let .ready(check) = phase { check } else { nil }
        // With no earlier read the retention window is unknown, so no script
        // is offered rather than one that names the wrong window.
        phase = .ready(RecordingConsentCheck(
            consent: consent,
            asksClients: previous != nil,
            audioRetentionDays: previous?.audioRetentionDays ?? 0,
            patientId: previous?.patientId
        ))
    }

    private func replacing(_ check: RecordingConsentCheck, with consent: RecordingConsent) -> RecordingConsentCheck {
        RecordingConsentCheck(
            consent: consent,
            asksClients: check.asksClients,
            audioRetentionDays: check.audioRetentionDays,
            patientId: check.patientId
        )
    }
}
