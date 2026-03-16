import AppKit
import Foundation
import os
import SwiftUI

/// Manages authentication state via ASWebAuthenticationSession and Firebase token refresh.
@MainActor
@Observable
final class AuthViewModel {
    // MARK: - Auth State

    enum AuthState: Equatable {
        case unauthenticated
        case authenticating
        case authenticated(email: String)
        case tokenExpired
    }

    var authState: AuthState = .unauthenticated
    var errorMessage: String?

    var authServerURL: String {
        get { KeychainManager.getToken(forKey: .authServerURL) ?? "https://app.pablo.health" }
        set { KeychainManager.saveToken(newValue, forKey: .authServerURL) }
    }

    var backendAPIURL: String {
        get { KeychainManager.getToken(forKey: .backendAPIURL) ?? "https://api.pablo.health" }
        set { KeychainManager.saveToken(newValue, forKey: .backendAPIURL) }
    }

    @ObservationIgnored
    @AppStorage("tokenExpiry") private var tokenExpiryTimestamp: Double = 0

    var tenantID: String {
        get { KeychainManager.getToken(forKey: .tenantID) ?? "" }
        set { KeychainManager.saveToken(newValue, forKey: .tenantID) }
    }

    /// Convenience accessor for the email when authenticated.
    var authenticatedEmail: String {
        if case let .authenticated(email) = authState {
            return email
        }
        return ""
    }

    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "AuthViewModel")

    // MARK: - Init

    init() {
        restoreAuthState()
    }

    // MARK: - Sign In

    func signIn() {
        guard let url = buildAuthURL() else {
            errorMessage = "Invalid auth server URL."
            return
        }

        authState = .authenticating
        errorMessage = nil

        // Open the auth page in the default browser. The callback will arrive
        // via the registered pablohealth:// URL scheme → onOpenURL → handleOpenURL.
        NSWorkspace.shared.open(url)
        logger.info("Opened auth URL in browser: \(url)")
    }

    /// Called from SwiftUI's `onOpenURL` when macOS routes a `pablohealth://` URL to the app.
    func handleOpenURL(_ url: URL) {
        guard url.scheme == AppConstants.callbackURLScheme else { return }
        handleAuthCallback(callbackURL: url)
    }

    // MARK: - Sign Out

    func signOut() {
        KeychainManager.deleteAll()
        tokenExpiryTimestamp = 0
        authState = .unauthenticated
        errorMessage = nil
        logger.info("User signed out")
    }

    // MARK: - Token Access

    /// Returns a valid ID token, refreshing if needed. Throws on failure.
    func getValidToken() async throws -> String {
        guard let idToken = KeychainManager.getToken(forKey: .idToken) else {
            authState = .tokenExpired
            throw TokenError.noToken
        }

        // Refresh if within 5-minute buffer of expiry
        let expiryDate = Date(timeIntervalSince1970: tokenExpiryTimestamp)
        if Date().addingTimeInterval(5 * 60) >= expiryDate {
            return try await refreshToken()
        }

        return idToken
    }

    // MARK: - Private

    private func restoreAuthState() {
        guard let idToken = KeychainManager.getToken(forKey: .idToken),
              let email = KeychainManager.getToken(forKey: .userEmail)
        else {
            authState = .unauthenticated
            return
        }

        let expiryDate = Date(timeIntervalSince1970: tokenExpiryTimestamp)
        if Date().addingTimeInterval(5 * 60) >= expiryDate {
            // Token expired or close to it — check if we can refresh
            if KeychainManager.getToken(forKey: .refreshToken) != nil {
                authState = .authenticated(email: email)
                logger.info("Restored auth state (token needs refresh)")
            } else {
                authState = .tokenExpired
                logger.info("Token expired and no refresh token available")
            }
        } else {
            authState = .authenticated(email: email)
            logger.info("Restored auth state, token valid")
        }

        // Also update expiry from JWT if we have a fresh token
        if let expiry = extractExpiry(from: idToken) {
            tokenExpiryTimestamp = expiry.timeIntervalSince1970
        }
    }

    private func buildAuthURL() -> URL? {
        if let error = URLValidator.validateScheme(authServerURL) {
            errorMessage = error
            return nil
        }
        let base = authServerURL.trimmingCharacters(in: .init(charactersIn: "/"))
        var components = URLComponents(string: "\(base)/native-auth")
        var queryItems = [URLQueryItem(name: "redirect_uri", value: AppConstants.redirectURI)]
        if !tenantID.isEmpty {
            queryItems.append(URLQueryItem(name: "tenant_id", value: tenantID))
        }
        components?.queryItems = queryItems
        return components?.url
    }

    private func handleAuthCallback(callbackURL: URL) {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems
        else {
            errorMessage = "Invalid callback URL."
            authState = .unauthenticated
            return
        }

        let params = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
            item.value.map { (item.name, $0) }
        })

        guard let code = params["code"] else {
            errorMessage = "Missing authorization code in callback."
            authState = .unauthenticated
            return
        }

        // Exchange the one-time code for tokens
        Task {
            await exchangeCodeForTokens(code: code)
        }
    }

    // MARK: - Code Exchange (RFC 8252)

    private func exchangeCodeForTokens(code: String) async {
        let base = authServerURL.trimmingCharacters(in: .init(charactersIn: "/"))
        guard let exchangeURL = URL(string: "\(base)/api/auth/native/exchange") else {
            errorMessage = "Invalid auth server URL."
            authState = .unauthenticated
            return
        }

        var request = URLRequest(url: exchangeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "code": code,
            "redirect_uri": AppConstants.redirectURI,
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try handleExchangeResponse(data: data, response: response)
        } catch let error as ExchangeError {
            errorMessage = error.errorDescription
            authState = .unauthenticated
        } catch {
            errorMessage = "Network error during sign in. Please try again."
            authState = .unauthenticated
            logger.error("Code exchange failed: \(error.localizedDescription)")
        }
    }

    private func handleExchangeResponse(data: Data, response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ExchangeError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw httpResponse.statusCode == 429
                ? ExchangeError.rateLimited
                : ExchangeError.httpError(httpResponse.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let idToken = json["id_token"] as? String,
              let refreshToken = json["refresh_token"] as? String
        else {
            throw ExchangeError.invalidTokenResponse
        }

        KeychainManager.saveToken(idToken, forKey: .idToken)
        KeychainManager.saveToken(refreshToken, forKey: .refreshToken)
        KeychainManager.saveToken(authServerURL, forKey: .authServerURL)

        let email = extractEmail(from: idToken) ?? "Unknown"
        KeychainManager.saveToken(email, forKey: .userEmail)

        if let expiry = extractExpiry(from: idToken) {
            tokenExpiryTimestamp = expiry.timeIntervalSince1970
        }

        authState = .authenticated(email: email)
        errorMessage = nil
        logger.info("Signed in successfully")
    }

    private func refreshToken() async throws -> String {
        guard let refreshToken = KeychainManager.getToken(forKey: .refreshToken) else {
            authState = .tokenExpired
            throw TokenError.noRefreshToken
        }

        guard let firebaseAPIKey = KeychainManager.getToken(forKey: .firebaseAPIKey),
              !firebaseAPIKey.isEmpty
        else {
            throw TokenError.noAPIKey
        }

        let refresher = TokenRefresher(apiKey: firebaseAPIKey)
        do {
            let response = try await refresher.refresh(using: refreshToken)

            KeychainManager.saveToken(response.idToken, forKey: .idToken)
            KeychainManager.saveToken(response.refreshToken, forKey: .refreshToken)
            tokenExpiryTimestamp = Date().addingTimeInterval(Double(response.expiresIn)).timeIntervalSince1970

            // Update email if it changed
            if let email = extractEmail(from: response.idToken) {
                KeychainManager.saveToken(email, forKey: .userEmail)
                authState = .authenticated(email: email)
            }

            return response.idToken
        } catch let refreshError as TokenRefresher.RefreshError {
            authState = .tokenExpired
            throw refreshError
        }
    }

    // MARK: - JWT Helpers

    private let jwtDecoder = JWTDecoder()

    func extractExpiry(from idToken: String) -> Date? {
        jwtDecoder.extractExpiry(from: idToken)
    }

    private func extractEmail(from idToken: String) -> String? {
        jwtDecoder.extractEmail(from: idToken)
    }
}

// MARK: - Errors

enum TokenError: LocalizedError {
    case noToken
    case noRefreshToken
    case noAPIKey

    var errorDescription: String? {
        switch self {
        case .noToken:
            "No authentication token found. Please sign in."
        case .noRefreshToken:
            "Session expired. Please sign in again."
        case .noAPIKey:
            "Firebase API key not configured."
        }
    }
}

// MARK: - Exchange Errors

private enum ExchangeError: LocalizedError {
    case invalidResponse
    case rateLimited
    case httpError(Int)
    case invalidTokenResponse

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Invalid response from server."
        case .rateLimited:
            "Too many attempts. Please wait and try again."
        case let .httpError(status):
            "Authentication failed (status \(status))."
        case .invalidTokenResponse:
            "Invalid token response from server."
        }
    }
}

// MARK: - JWT Decoder

struct JWTDecoder {
    func decodePayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    func extractExpiry(from jwt: String) -> Date? {
        guard let payload = decodePayload(jwt),
              let exp = payload["exp"] as? TimeInterval
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    func extractEmail(from jwt: String) -> String? {
        decodePayload(jwt)?["email"] as? String
    }
}
