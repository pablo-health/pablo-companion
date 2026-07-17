import AppKit
import CompanionAuthCore
import CryptoKit
import Foundation
import os
import SwiftUI

/// Manages authentication state via loopback redirect (RFC 8252 §7.3) and Firebase token refresh.
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

    /// Stored and hydrated once, not a computed Keychain passthrough.
    ///
    /// @Observable only instruments stored properties, so as a computed property
    /// this registered no dependency and SwiftUI never invalidated on change —
    /// LoginView's inline validation could not fire while typing. It also ran
    /// SecItemUpdate on every keystroke and SecItemCopyMatching on every read.
    var authServerURL: String {
        didSet { KeychainManager.saveToken(authServerURL, forKey: .authServerURL) }
    }

    var backendAPIURL: String {
        didSet { KeychainManager.saveToken(backendAPIURL, forKey: .backendAPIURL) }
    }

    @ObservationIgnored
    private var tokenExpiryTimestamp: Double {
        get {
            guard let stored = KeychainManager.getToken(forKey: .tokenExpiry) else { return 0 }
            return Double(stored) ?? 0
        }
        set {
            KeychainManager.saveToken(String(newValue), forKey: .tokenExpiry)
        }
    }

    var tenantID: String {
        didSet { KeychainManager.saveToken(tenantID, forKey: .tenantID) }
    }

    /// Convenience accessor for the email when authenticated.
    var authenticatedEmail: String {
        if case let .authenticated(email) = authState {
            return email
        }
        return ""
    }

    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "AuthViewModel")

    /// PKCE code verifier for the current auth flow (RFC 7636).
    private var pkceCodeVerifier: String?

    /// OAuth 2.0 `state` for the current flow (RFC 6749 §10.12 — CSRF protection).
    /// Generated at flow start, echoed by the authz server, verified on callback.
    private var oauthState: String?

    /// Active loopback server for the current sign-in attempt (if any).
    private var loopbackServer: LoopbackServer?

    // MARK: - Init

    init() {
        // Hydrate once. A saved value means someone pointed the app elsewhere,
        // which is what `isAdvancedVisible` keys off.
        let savedAuthServerURL = KeychainManager.getToken(forKey: .authServerURL)
            ?? AppConstants.defaultAuthServerURL
        authServerURL = savedAuthServerURL
        backendAPIURL = KeychainManager.getToken(forKey: .backendAPIURL)
            ?? AppConstants.defaultBackendAPIURL
        tenantID = KeychainManager.getToken(forKey: .tenantID) ?? ""
        // Read the local, not the property: Swift requires every stored property
        // to be initialised before `self` is readable.
        isAdvancedVisible = savedAuthServerURL != AppConstants.defaultAuthServerURL
        restoreAuthState()
    }

    /// Whether the server URL field is shown. Hidden for a normal install —
    /// a therapist has no idea what to put there — and revealed on request or
    /// when a saved URL differs from the default, so a self-hoster can see where
    /// they are pointed. Mirrors Windows `AuthViewModel.IsAdvancedVisible`.
    var isAdvancedVisible: Bool

    func showAdvanced() {
        isAdvancedVisible = true
    }

    // MARK: - Sign In

    /// Starts the OAuth sign-in flow using a loopback redirect (RFC 8252 §7.3).
    /// Spins up a local HTTP server, opens the browser, waits for the callback.
    func signIn() async {
        // Cancel any previous in-flight sign-in
        loopbackServer?.stop()
        loopbackServer = nil

        let server = LoopbackServer()
        loopbackServer = server

        do {
            let port = try await server.start()
            logger.info("Loopback server started on port \(port)")

            guard let url = buildAuthURL(redirectURI: server.redirectURI) else {
                errorMessage = "Invalid auth server URL."
                server.stop()
                loopbackServer = nil
                return
            }

            authState = .authenticating
            errorMessage = nil

            NSWorkspace.shared.open(url)
            logger.info("Opened auth URL in browser")

            let callbackURL = try await server.waitForCallback(timeout: 120)

            guard let code = extractValidatedAuthCode(from: callbackURL) else { return }

            await exchangeCodeForTokens(code: code, redirectURI: server.redirectURI)
        } catch let error as LoopbackServer.ServerError {
            errorMessage = error.errorDescription
            authState = .unauthenticated
        } catch {
            errorMessage = "Sign-in failed. Please try again."
            authState = .unauthenticated
            logger.error("Sign-in error: \(error.localizedDescription)")
        }

        server.stop()
        loopbackServer = nil
    }

    /// Validates the callback URL: extracts the authorization code and verifies the
    /// `state` parameter matches the one we generated (constant-time compare). On any
    /// failure, sets `errorMessage` / `authState` and returns nil.
    private func extractValidatedAuthCode(from callbackURL: URL) -> String? {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              Self.isValidAuthCode(code)
        else {
            errorMessage = "Invalid or missing authorization code in callback."
            authState = .unauthenticated
            return nil
        }

        let returnedState = components.queryItems?.first(where: { $0.name == "state" })?.value
        defer { oauthState = nil }
        guard let expectedState = oauthState,
              let returnedState,
              PKCEHelper.constantTimeEquals(expectedState, returnedState)
        else {
            errorMessage = "Sign-in failed. Please try again."
            authState = .unauthenticated
            logger.error("OAuth state mismatch on callback")
            return nil
        }
        return code
    }

    // MARK: - Sign Out

    func signOut() {
        KeychainManager.deleteAuthTokens()
        tokenExpiryTimestamp = 0
        authState = .unauthenticated
        errorMessage = nil
        logger.info("User signed out")
    }

    // MARK: - Server Session Rejection

    /// Guards against parallel 401s (concurrent requests) stacking sign-outs.
    /// Stored here (extensions can't add storage); the handler lives in
    /// `AuthViewModel+SessionExpiry.swift`.
    @ObservationIgnored
    var isHandlingAuthRejection = false

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

    private func buildAuthURL(redirectURI: String) -> URL? {
        if let error = URLValidator.validateScheme(authServerURL) {
            errorMessage = error
            return nil
        }
        let base = authServerURL.trimmingCharacters(in: .init(charactersIn: "/"))
        var components = URLComponents(string: "\(base)/native-auth")
        var queryItems = [URLQueryItem(name: "redirect_uri", value: redirectURI)]
        if !tenantID.isEmpty {
            queryItems.append(URLQueryItem(name: "tenant_id", value: tenantID))
        }

        // PKCE (RFC 7636) — generate verifier and send challenge
        let verifier = PKCEHelper.generateCodeVerifier()
        pkceCodeVerifier = verifier
        queryItems.append(URLQueryItem(name: "code_challenge", value: PKCEHelper.codeChallenge(for: verifier)))
        queryItems.append(URLQueryItem(name: "code_challenge_method", value: "S256"))

        // OAuth state (RFC 6749 §10.12) — CSRF / cross-flow protection
        let state = PKCEHelper.generateState()
        oauthState = state
        queryItems.append(URLQueryItem(name: "state", value: state))

        components?.queryItems = queryItems
        return components?.url
    }

    /// Validates that an authorization code contains only safe characters and is
    /// within the expected length range. Matches the Windows validation pattern.
    private static func isValidAuthCode(_ code: String) -> Bool {
        let pattern = #"^[a-zA-Z0-9_\-\.]{10,2000}$"#
        return code.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Code Exchange (RFC 8252)

    private func exchangeCodeForTokens(code: String, redirectURI: String) async {
        let base = authServerURL.trimmingCharacters(in: .init(charactersIn: "/"))
        guard let exchangeURL = URL(string: "\(base)/api/auth/native/exchange") else {
            errorMessage = "Invalid auth server URL."
            authState = .unauthenticated
            return
        }

        var request = URLRequest(url: exchangeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "code": code,
            "redirect_uri": redirectURI,
        ]
        if let verifier = pkceCodeVerifier {
            body["code_verifier"] = verifier
            pkceCodeVerifier = nil
        }

        // Device enrollment — registers this install so the web dashboard can
        // recognise it and route handoffs here. The backend treats `enrollment`
        // as optional, but a *present* object must be schema-valid (it carries
        // the required device_public_key_jwk + key_storage); a partial object
        // would 422 the whole exchange. So attach it only when we can build a
        // complete payload, and omit it otherwise rather than send a partial.
        let installID = KeychainManager.getOrCreateInstallID()
        if let enrollment = DeviceEnrollment.payload(installID: installID) {
            body["enrollment"] = enrollment
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

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

        // Bring the app window to the foreground after completing the token exchange.
        // The browser still has focus at this point since the user authenticated there.
        NSApplication.shared.activate(ignoringOtherApps: true)
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
