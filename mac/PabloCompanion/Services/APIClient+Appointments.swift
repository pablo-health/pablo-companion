import CompanionSessionCore
import Foundation

extension APIClient {
    /// Creates a therapy session linked to a calendar appointment.
    /// `askingConsentOnRecording`: the clinician asks about AI-assisted notes
    /// once recording starts (a telehealth client with no answer on file).
    func startSessionFromAppointment(
        appointmentId: String,
        askingConsentOnRecording: Bool = false
    ) async throws -> Session {
        var request = try await buildRequest(
            "POST",
            path: "/api/appointments/\(appointmentId)/start-session"
        )
        request.httpBody = RecordingConsentClient.startSessionBody(askingConsentOnRecording: askingConsentOnRecording)
        let (data, response) = try await URLSession.shared.data(for: request)
        try mapHTTPErrors(data: data, response: response)

        let session: Session = try handleResponse(data, response)
        logger.info("Started session from appointment")
        return session
    }
}
