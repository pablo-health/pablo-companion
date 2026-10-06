import CompanionSessionCore
import Foundation

/// The two calls the consent prompt makes. A protocol so the view model can be
/// tested with a fake instead of the network.
@MainActor
protocol RecordingConsentService: AnyObject {
    /// `modality`: where the session is, when the caller knows; `nil` reads
    /// it from the appointment.
    func checkRecordingConsent(
        appointmentId: String,
        patientId: String?,
        modality: AiConsentModality?
    ) async throws -> RecordingConsentCheck
    func recordConsent(_ answer: AiConsentAnswer, patientId: String) async throws
}

// MARK: - Recording consent (shared CompanionSessionCore wire path)

extension APIClient: RecordingConsentService {
    /// The shared consent client, bound to this `APIClient`'s auth and device
    /// binding, like the audio upload client.
    private var recordingConsentClient: RecordingConsentClient {
        RecordingConsentClient(
            baseURLString: baseURLString,
            token: { [self] in try await requireToken() },
            attachBinding: { APIClient.attachDeviceBinding(to: &$0) }
        )
    }

    func checkRecordingConsent(
        appointmentId: String,
        patientId: String?,
        modality: AiConsentModality?
    ) async throws -> RecordingConsentCheck {
        do {
            return try await recordingConsentClient.check(
                appointmentId: appointmentId,
                patientId: patientId,
                modality: modality
            )
        } catch let error as ConsentRequestError {
            throw mapConsentError(error)
        }
    }

    func recordConsent(_ answer: AiConsentAnswer, patientId: String) async throws {
        do {
            try await recordingConsentClient.record(answer, patientId: patientId)
            logger.info("Recorded client consent answer")
        } catch let error as ConsentRequestError {
            throw mapConsentError(error)
        }
    }

    /// Same contract as `mapHTTPErrors`: a 401 sends the clinician back to
    /// sign-in rather than leaving the prompt to retry a dead session.
    private func mapConsentError(_ error: ConsentRequestError) -> Error {
        guard error.statusCode == 401 else { return error }
        onAuthRejected?(error.code == Self.idleTimeoutCode)
        return PabloError.unauthenticated
    }
}
