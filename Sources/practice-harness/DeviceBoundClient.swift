#if canImport(CompanionAuthCore)

import CompanionAuthCore
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Shared device-bound HTTP plumbing for the headless scenarios.
///
/// Owns the enrollment handshake (`/api/auth/native/code` → `/exchange` carrying
/// a real `DeviceEnrollment` payload) and DPoP-signed requests (`Bearer` +
/// `X-Install-ID` + a fresh `DPoPProof`), so the `dpop` and `record` scenarios
/// drive the identical device-binding code the shipping app uses. Every signed
/// request produces its proof from the actual `DPoPProof.make`, so a drift
/// between the client crypto and `backend/app/middleware/dpop.py` fails here.
struct DeviceBoundClient {
    let baseURL: String
    let installID: String

    struct Response {
        let status: Int
        let body: Data
        var json: [String: Any]? {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        }

        var bodyPrefix: String {
            String(decoding: body.prefix(200), as: UTF8.self)
        }
    }

    /// Result of the enrollment handshake.
    struct Enrollment {
        /// Refreshed id token returned by `/exchange` (falls back to the input).
        let idToken: String
        /// HTTP status of the `/exchange` call (200 on success).
        let exchangeStatus: Int
        /// `key_storage` reported by the device key (`secureEnclave` / `software`).
        let keyStorage: String
    }

    /// The redirect URI only has to be an allowed native scheme — the harness
    /// never opens it; the code comes back in the POST body.
    static let defaultRedirectURI = "pablohealth://auth/callback"

    // MARK: - Enrollment

    /// Runs the OAuth code exchange carrying a real device-enrollment payload,
    /// returning the refreshed id token. Throws if `/native/code` fails or no
    /// device key can be provisioned.
    func enroll(
        idToken: String,
        refreshToken: String,
        redirectURI: String = defaultRedirectURI
    ) async throws -> Enrollment {
        let code = try await postJSON(
            path: "/api/auth/native/code",
            body: ["id_token": idToken, "refresh_token": refreshToken, "redirect_uri": redirectURI]
        )
        guard let oneTimeCode = code.json?["code"] as? String, code.status == 200 else {
            throw DeviceBoundError("native/code failed: \(code.status) \(code.bodyPrefix)")
        }

        guard let enrollment = DeviceEnrollment.payload(installID: installID) else {
            throw DeviceBoundError("DeviceEnrollment.payload returned nil — no device key could be provisioned")
        }
        let keyStorage = (enrollment["key_storage"] as? String) ?? "?"

        let exchange = try await postJSON(
            path: "/api/auth/native/exchange",
            body: ["code": oneTimeCode, "redirect_uri": redirectURI, "enrollment": enrollment]
        )
        let refreshed = (exchange.json?["id_token"] as? String) ?? idToken
        return Enrollment(idToken: refreshed, exchangeStatus: exchange.status, keyStorage: keyStorage)
    }

    // MARK: - HTTP

    /// Unauthenticated JSON POST (the native code/exchange endpoints).
    func postJSON(path: String, body: [String: Any]) async throws -> Response {
        guard let url = URL(string: baseURL + path) else { throw DeviceBoundError("bad url \(path)") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    /// Authenticated request carrying the device binding exactly like the app:
    /// `Bearer` + `X-Install-ID` + a fresh `DPoP` proof (or a caller-supplied
    /// proof for replay tests, or no proof at all for the negative test).
    func request(
        _ method: String,
        path: String,
        idToken: String,
        jsonBody: [String: Any]? = nil,
        presetProof: String? = nil,
        omitProof: Bool = false
    ) async throws -> Response {
        guard let url = URL(string: baseURL + path) else { throw DeviceBoundError("bad url \(path)") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.setValue(installID, forHTTPHeaderField: "X-Install-ID")
        if !omitProof {
            guard let proof = presetProof ?? DPoPProof.make(method: method, url: url) else {
                throw DeviceBoundError("DPoPProof.make returned nil for \(method) \(path)")
            }
            request.setValue(proof, forHTTPHeaderField: "DPoP")
        }
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DeviceBoundError("non-HTTP response from \(request.url?.path ?? "?")")
        }
        return Response(status: http.statusCode, body: data)
    }

    // MARK: - Helpers

    func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

struct DeviceBoundError: LocalizedError {
    let message: String
    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

#endif
