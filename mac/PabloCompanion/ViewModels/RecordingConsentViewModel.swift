import CompanionSessionCore
import Foundation
import os

/// The client's answer about AI-assisted notes, read before the microphone arms.
///
/// When the practice asks its clients, a client who declined stops the start,
/// and a client nobody has asked yet gets three choices: record a verbal OK for
/// today and start, record anyway, or cancel. With the setting off this is
/// always ``RecordingConsent/clear`` and no prompt appears.
///
/// A failed read does not block the start: the server refuses a declined
/// client's recording on its own, and ``showRefusal(declinedOn:)`` turns that
/// refusal into the same declined message.
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
    /// logged and treated as clear, because the server still refuses a
    /// declined client.
    ///
    /// `webAlreadyAsked`: a hand-off whose web start already asked "No consent
    /// on file" and was told to record anyway. A missing answer then reads as
    /// clear; a decline is still read and still stops.
    @discardableResult
    func check(
        appointmentId: String,
        patientId: String?,
        webAlreadyAsked: Bool = false,
        service: RecordingConsentService
    ) async -> RecordingConsent {
        generation += 1
        let current = generation
        phase = .checking
        saveError = nil
        do {
            let read = try await service.checkRecordingConsent(appointmentId: appointmentId, patientId: patientId)
            guard current == generation else { return .clear }
            let check = RecordingConsentCheck(
                consent: read.consent.handedOff(webAlreadyAsked: webAlreadyAsked),
                asksClients: read.asksClients,
                audioRetentionDays: read.audioRetentionDays,
                patientId: read.patientId
            )
            phase = .ready(check)
            return check.consent
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
        generation += 1
        let previous: RecordingConsentCheck? = if case let .ready(check) = phase { check } else { nil }
        phase = .ready(RecordingConsentCheck(
            consent: .declined(on: declinedOn),
            asksClients: true,
            audioRetentionDays: previous?.audioRetentionDays ?? 0,
            patientId: previous?.patientId
        ))
        saveError = nil
    }

    /// Records that the client agreed today. Returns true when saved, and the
    /// prompt then reads as clear; false leaves ``saveError`` set.
    func recordAgreedToday(service: RecordingConsentService) async -> Bool {
        guard case let .ready(check) = phase, let patientId = check.patientId else { return false }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            try await service.recordAgreedToday(patientId: patientId)
            phase = .ready(RecordingConsentCheck(
                consent: .clear,
                asksClients: check.asksClients,
                audioRetentionDays: check.audioRetentionDays,
                patientId: patientId
            ))
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
    }
}
