import CompanionSessionCore
import Foundation
import os

/// Asking a client about AI-assisted notes once recording has started, so the
/// answer is on the recording. Holds the script's retention window, who
/// answered, and (over telehealth) where the client said they were, and saves
/// the answer to the client's record as given in person or over telehealth.
@MainActor
@Observable
final class AskOnRecordingViewModel {
    /// What is being asked, for which session. Identifiable to drive a sheet.
    struct Ask: Identifiable, Equatable {
        let id = UUID()
        let sessionId: String
        /// `nil` when the client is not known here; the answer is then
        /// recorded on the chart in the web app.
        let patientId: String?
        /// `nil` when the practice's window is not known; no script is shown.
        let retentionDays: Int?
        /// Where the session is; the answer is saved as given there, and only
        /// telehealth asks where the client is.
        let modality: AiConsentModality
    }

    /// The ask on screen, if any.
    var ask: Ask?
    var giver: AiConsentGiver = .client
    /// Where the client said they were, in their words. Optional.
    var location = ""
    private(set) var isSaving = false
    private(set) var saveError: String?
    /// The client declined and the recording was stopped and deleted; the
    /// panel says so in place of the script.
    private(set) var recordingDeleted = false

    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "AskOnRecording")

    func begin(sessionId: String, patientId: String?, retentionDays: Int?, modality: AiConsentModality) {
        ask = Ask(sessionId: sessionId, patientId: patientId, retentionDays: retentionDays, modality: modality)
        giver = .client
        location = ""
        isSaving = false
        saveError = nil
        recordingDeleted = false
    }

    func markRecordingDeleted() {
        recordingDeleted = true
    }

    /// Whether the panel asks where the client is: telehealth only.
    var asksLocation: Bool {
        ask?.modality == .telehealth
    }

    /// The answer as it is sent: where the session is, by ``giver``, and over
    /// telehealth with the place if one was given. `nil` with nothing asked.
    func answer(decision: String) -> AiConsentAnswer? {
        guard let ask else { return nil }
        return AiConsentAnswer(
            decision: decision,
            modality: ask.modality,
            consentedBy: giver,
            clientStatedLocation: asksLocation ? location : nil
        )
    }

    /// Saves the client's answer. Returns true when saved; false leaves
    /// ``saveError`` set (or does nothing when the client is not known).
    func record(decision: String, service: RecordingConsentService) async -> Bool {
        guard let patientId = ask?.patientId, let answer = answer(decision: decision), !isSaving else {
            return false
        }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            try await service.recordConsent(answer, patientId: patientId)
            return true
        } catch {
            logger.error("Recording consent answer failed: \(error.localizedDescription)")
            saveError = RecordingConsentCopy.saveFailed
            return false
        }
    }

    func dismiss() {
        ask = nil
        location = ""
        saveError = nil
        recordingDeleted = false
    }
}
