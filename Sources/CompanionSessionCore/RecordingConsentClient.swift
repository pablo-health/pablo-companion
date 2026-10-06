import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads a client's answer about AI-assisted notes before a recording arms,
/// and records a verbal "agreed today".
///
/// Three existing endpoints, called with the clinician's own credentials:
/// - `GET /api/users/me/practice/ai-notes-consent` — whether the practice asks,
///   and its audio retention window (read aloud in the script).
/// - `GET /api/appointments/{id}` — the appointment's client, when the caller
///   only holds an appointment id (a web handoff carries no client id).
/// - `GET` / `POST /api/patients/{id}/ai-consent` — the client's answer.
///
/// The setting is read first: with it off, the client is never looked up, so
/// no consent read is audited for a practice that does not ask.
///
/// Auth and device binding are injected, as for ``AudioUploadClient``.
public struct RecordingConsentClient: Sendable {
    private let baseURLString: String
    private let token: @Sendable () async throws -> String
    private let attachBinding: @Sendable (inout URLRequest) -> Void
    private let session: URLSession

    public init(
        baseURLString: String,
        token: @escaping @Sendable () async throws -> String,
        attachBinding: @escaping @Sendable (inout URLRequest) -> Void,
        session: URLSession = .shared
    ) {
        self.baseURLString = baseURLString
        self.token = token
        self.attachBinding = attachBinding
        self.session = session
    }

    /// The consent picture for one appointment. Pass `patientId` when it is
    /// already known (an appointment from today's list) to skip the
    /// appointment lookup.
    public func check(appointmentId: String, patientId: String? = nil) async throws -> RecordingConsentCheck {
        let setting: Setting = try await send("GET", path: "/api/users/me/practice/ai-notes-consent")
        guard setting.askClientsAboutAiNotes else {
            return RecordingConsentCheck(
                consent: .clear,
                asksClients: false,
                audioRetentionDays: setting.audioRetentionDays,
                patientId: nil
            )
        }

        var clientId = patientId ?? ""
        if clientId.isEmpty {
            let appointment: AppointmentClient = try await send("GET", path: "/api/appointments/\(appointmentId)")
            clientId = appointment.patientId ?? ""
        }
        guard !clientId.isEmpty else {
            // No client matched to the appointment yet. The server refuses to
            // start such a session on its own; nothing to ask about here.
            return RecordingConsentCheck(
                consent: .clear,
                asksClients: true,
                audioRetentionDays: setting.audioRetentionDays,
                patientId: nil
            )
        }

        let record: Record = try await send("GET", path: "/api/patients/\(clientId)/ai-consent")
        return RecordingConsentCheck(
            consent: RecordingConsent.evaluate(asksClients: true, current: record.current),
            asksClients: true,
            audioRetentionDays: setting.audioRetentionDays,
            patientId: clientId
        )
    }

    /// Records that the client agreed today. No date is sent: the server dates
    /// it on the clinician's own calendar day, so an evening entry is not
    /// dated tomorrow.
    public func recordAgreedToday(patientId: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["decision": AiConsentEntry.consented])
        let _: Record = try await send("POST", path: "/api/patients/\(patientId)/ai-consent", body: body)
    }

    // MARK: - Wire

    private struct Setting: Decodable {
        let askClientsAboutAiNotes: Bool
        let audioRetentionDays: Int

        enum CodingKeys: String, CodingKey {
            case askClientsAboutAiNotes = "ask_clients_about_ai_notes"
            case audioRetentionDays = "audio_retention_days"
        }
    }

    private struct AppointmentClient: Decodable {
        let patientId: String?

        enum CodingKeys: String, CodingKey {
            case patientId = "patient_id"
        }
    }

    private struct Record: Decodable {
        let current: AiConsentEntry?
    }

    private func send<T: Decodable>(_ method: String, path: String, body: Data? = nil) async throws -> T {
        guard let url = URL(string: "\(baseURLString)\(path)") else {
            throw ConsentRequestError(statusCode: -1, code: nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        request.setValue("pablo-companion-macos/1.0", forHTTPHeaderField: "X-Client-Type")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        attachBinding(&request)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200 ... 299).contains(status) else {
            throw ConsentRequestError(statusCode: status, code: SessionUploadError.parseEnvelope(data)?.code)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// A non-2xx response from a consent request. Carries no PHI: a status and the
/// backend's `error.code`, so the app can route a `401` to re-auth.
public struct ConsentRequestError: Error, Equatable, Sendable, CustomStringConvertible {
    public let statusCode: Int
    public let code: String?

    public init(statusCode: Int, code: String?) {
        self.statusCode = statusCode
        self.code = code
    }

    public var description: String {
        "consent request failed: HTTP \(statusCode)" + (code.map { " [\($0)]" } ?? "")
    }
}
