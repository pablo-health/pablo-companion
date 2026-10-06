import CompanionSessionCore
import Foundation
import os

/// The client's answer about AI-assisted notes, read before the microphone arms.
///
/// When the practice asks its clients, a client who declined stops the start.
/// A client nobody has asked yet gets, in person, three choices: record a
/// verbal OK for today and start, record anyway, or cancel. Over telehealth
/// they get two: ask once recording starts ("Ask now"), or don't record. With
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
    private(set) var isSaving = false
    /// Shown under the choices when "agreed today" could not be saved.
    private(set) var saveError: String?
    /// Who answers "agreed today": the client, or a parent or guardian.
    var giver: AiConsentGiver = .client

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

    /// The client the answer belongs to, for "agreed today".
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
        saveError = nil
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
        showServerAnswer(.askOnRecording)
    }

    /// "Ask now": the start tells the server the clinician is asking once
    /// recording starts, and the script follows once recording is running.
    func askNow() {
        guard case let .ready(check) = phase, check.consent == .askOnRecording else { return }
        phase = .ready(replacing(check, with: .askingOnRecording))
    }

    /// Records that the client (or the chosen ``giver``) agreed today, in
    /// person. Returns true when saved, and the prompt then reads as clear;
    /// false leaves ``saveError`` set.
    func recordAgreedToday(service: RecordingConsentService) async -> Bool {
        guard case let .ready(check) = phase, let patientId = check.patientId else { return false }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            // Only an in-person start reaches "agreed today" (telehealth asks
            // on the recording), so that is how it was given.
            try await service.recordConsent(.agreedInPerson(by: giver), patientId: patientId)
            phase = .ready(replacing(check, with: .clear))
            return true
        } catch {
            logger.error("Recording consent failed: \(error.localizedDescription)")
            saveError = RecordingConsentCopy.saveFailed
            return false
        }
    }

    func reset() {
        generation += 1
        phase = .idle
        isSaving = false
        saveError = nil
        giver = .client
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
        saveError = nil
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
