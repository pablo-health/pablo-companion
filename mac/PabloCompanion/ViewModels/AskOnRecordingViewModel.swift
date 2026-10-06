import CompanionSessionCore
import Foundation
import os

/// Asking a telehealth client about AI-assisted notes once recording has
/// started, so the answer is on the recording. Holds the script's retention
/// window, who answered, where the client said they were, and saves the answer
/// to the client's record as given over telehealth.
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
    }

    /// The ask on screen, if any.
    var ask: Ask?
    var giver: AiConsentGiver = .client
    /// Where the client said they were, in their words. Optional.
    var location = ""
    private(set) var isSaving = false
    private(set) var saveError: String?

    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "AskOnRecording")

    func begin(sessionId: String, patientId: String?, retentionDays: Int?) {
        ask = Ask(sessionId: sessionId, patientId: patientId, retentionDays: retentionDays)
        giver = .client
        location = ""
        isSaving = false
        saveError = nil
    }

    /// The answer as it is sent: over telehealth, by ``giver``, with the place
    /// if one was given.
    func answer(decision: String) -> AiConsentAnswer {
        AiConsentAnswer(
            decision: decision,
            modality: .telehealth,
            consentedBy: giver,
            clientStatedLocation: location
        )
    }

    /// Saves the client's answer. Returns true when saved; false leaves
    /// ``saveError`` set (or does nothing when the client is not known).
    func record(decision: String, service: RecordingConsentService) async -> Bool {
        guard let patientId = ask?.patientId, !isSaving else { return false }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            try await service.recordConsent(answer(decision: decision), patientId: patientId)
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
    }
}
