import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal Firebase Identity Platform REST client for the harness's
/// self-contained sign-in. Ported from the e2e suite's `firebaseAuth.ts` so the
/// runner can authenticate the pinned test user without Node or any prior
/// e2e state.
///
/// Strategy (matches THERAPY-71d5): try the cached refresh token first (cheap,
/// avoids the rate-limited `mfaSignIn:finalize` quota); on ANY failure — 401,
/// expired/revoked refresh token, network error — fall back to the full TOTP
/// MFA dance. Either path returns a fresh, MFA-stamped ID token plus a NEW
/// refresh token (the old one is invalidated within seconds of exchange).
struct FirebaseAuth {
    let apiKey: String

    private let idpBase = "https://identitytoolkit.googleapis.com"
    private let secureTokenBase = "https://securetoken.googleapis.com"

    struct MintResult {
        let idToken: String
        let refreshToken: String
        let mode: String
    }

    enum AuthError: LocalizedError {
        case http(path: String, status: Int, body: String)
        case shape(String)

        var errorDescription: String? {
            switch self {
            case let .http(path, status, body): "\(path) failed: \(status) \(body)"
            case let .shape(message): message
            }
        }
    }

    func mint(
        refreshToken: String?, email: String?, password: String?, totpSecret: String?
    ) async throws -> MintResult {
        if let refreshToken, !refreshToken.isEmpty {
            do {
                let (id, rt) = try await exchangeRefreshToken(refreshToken)
                return MintResult(idToken: id, refreshToken: rt, mode: "refresh-exchange")
            } catch {
                FileHandle.standardError.write(Data(
                    "refresh exchange failed, falling back to TOTP MFA: \(error.localizedDescription)\n".utf8
                ))
            }
        }

        guard let email, let password, let totpSecret,
              !email.isEmpty, !password.isEmpty, !totpSecret.isEmpty
        else {
            throw AuthError.shape("TOTP fallback requires FB_EMAIL, FB_PASSWORD, FB_TOTP_SECRET")
        }
        let (id, rt) = try await signInWithMfa(email: email, password: password, totpSecret: totpSecret)
        return MintResult(idToken: id, refreshToken: rt, mode: "totp-mfa")
    }

    // MARK: - Refresh-token exchange (securetoken)

    private func exchangeRefreshToken(_ refreshToken: String) async throws -> (String, String) {
        guard let url = URL(string: "\(secureTokenBase)/v1/token?key=\(apiKey)") else {
            throw AuthError.shape("bad securetoken URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=refresh_token&refresh_token=\(refreshToken)".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        try ensureOK(response, data, path: "securetoken/v1/token")

        // The endpoint returns snake_case despite the rest of IDP being camelCase.
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let id = json["id_token"] as? String, let rt = json["refresh_token"] as? String else {
            throw AuthError.shape("securetoken response missing id_token/refresh_token")
        }
        return (id, rt)
    }

    // MARK: - Password + TOTP MFA

    private func signInWithMfa(
        email: String, password: String, totpSecret: String
    ) async throws -> (String, String) {
        let pw = try await idpPost("v1/accounts:signInWithPassword", body: [
            "email": email,
            "password": password,
            "returnSecureToken": true,
        ])

        guard let pending = pw["mfaPendingCredential"] as? String else {
            throw AuthError.shape("no mfaPendingCredential (account not MFA-enrolled?)")
        }
        let mfaInfo = pw["mfaInfo"] as? [[String: Any]]
        guard let enrollmentId = mfaInfo?.first?["mfaEnrollmentId"] as? String else {
            throw AuthError.shape("no mfaInfo[0].mfaEnrollmentId in sign-in response")
        }

        let code = try await TOTP.freshCode(base32Secret: totpSecret)
        let final = try await idpPost("v2/accounts/mfaSignIn:finalize", body: [
            "mfaPendingCredential": pending,
            "mfaEnrollmentId": enrollmentId,
            "totpVerificationInfo": ["verificationCode": code],
        ])

        guard let id = final["idToken"] as? String, let rt = final["refreshToken"] as? String else {
            throw AuthError.shape("mfaSignIn:finalize response missing idToken/refreshToken")
        }
        return (id, rt)
    }

    // MARK: - Helpers

    private func idpPost(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: "\(idpBase)/\(path)?key=\(apiKey)") else {
            throw AuthError.shape("bad IDP URL for \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try ensureOK(response, data, path: path)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func ensureOK(_ response: URLResponse, _ data: Data, path: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.shape("\(path): no HTTP response")
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw AuthError.http(path: path, status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
    }
}
