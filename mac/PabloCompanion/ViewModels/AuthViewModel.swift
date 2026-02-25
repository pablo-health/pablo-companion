import AuthenticationServices
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

    @ObservationIgnored
    @AppStorage("authServerURL") var authServerURL = "http://localhost:3000"

    @ObservationIgnored
    @AppStorage("backendAPIURL") var backendAPIURL = "http://localhost:8000"

    @ObservationIgnored
    @AppStorage("tokenExpiry") private var tokenExpiryTimestamp: Double = 0

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

        // Launch from a file-scope free function that creates the completion
        // closure internally, so it is NOT defined in a @MainActor context.
        // This prevents Swift 6 from inserting a runtime isolation assert
        // (dispatch_assert_queue_fail) when the framework calls back on an
        // XPC thread. See: https://github.com/swiftlang/swift/issues/75453
        launchWebAuthSession(url: url, viewModel: self)
        logger.info("ASWebAuthenticationSession started")
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

        // Restore auth server URL from Keychain
        if let savedURL = KeychainManager.getToken(forKey: .authServerURL) {
            authServerURL = savedURL
        }

        let expiryDate = Date(timeIntervalSince1970: tokenExpiryTimestamp)
        if Date().addingTimeInterval(5 * 60) >= expiryDate {
            // Token expired or close to it — check if we can refresh
            if KeychainManager.getToken(forKey: .refreshToken) != nil {
                authState = .authenticated(email: email)
                logger.info("Restored auth state for \(email) (token needs refresh)")
            } else {
                authState = .tokenExpired
                logger.info("Token expired and no refresh token available")
            }
        } else {
            authState = .authenticated(email: email)
            logger.info("Restored auth state for \(email), token valid")
        }

        // Also update expiry from JWT if we have a fresh token
        if let expiry = extractExpiry(from: idToken) {
            tokenExpiryTimestamp = expiry.timeIntervalSince1970
        }
    }

    private func buildAuthURL() -> URL? {
        let base = authServerURL.trimmingCharacters(in: .init(charactersIn: "/"))
        let redirectURI = "therapyrecorder://callback"
        return URL(string: "\(base)/native-auth?redirect_uri=\(redirectURI)")
    }

    func handleAuthCallback(callbackURL: URL?, error: (any Error)?) {
        if let error {
            if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                logger.info("User cancelled sign in")
                authState = .unauthenticated
                return
            }
            logger.error("Auth error: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            authState = .unauthenticated
            return
        }

        guard let callbackURL,
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems
        else {
            errorMessage = "Invalid callback URL."
            authState = .unauthenticated
            return
        }

        let params = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
            item.value.map { (item.name, $0) }
        })

        guard let idToken = params["id_token"],
              let refreshToken = params["refresh_token"]
        else {
            errorMessage = "Missing tokens in callback."
            authState = .unauthenticated
            return
        }

        // Store tokens and auth server URL for session restore
        KeychainManager.saveToken(idToken, forKey: .idToken)
        KeychainManager.saveToken(refreshToken, forKey: .refreshToken)
        KeychainManager.saveToken(authServerURL, forKey: .authServerURL)

        // Extract email from JWT
        let email = extractEmail(from: idToken) ?? params["email"] ?? "Unknown"
        KeychainManager.saveToken(email, forKey: .userEmail)

        // Extract and store expiry
        if let expiry = extractExpiry(from: idToken) {
            tokenExpiryTimestamp = expiry.timeIntervalSince1970
        }

        authState = .authenticated(email: email)
        errorMessage = nil
        logger.info("Signed in as \(email)")
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

// MARK: - Web Auth Session Launcher

/// Sendable wrapper for weak references that cross isolation boundaries.
private struct WeakRef<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
}

/// Launches ASWebAuthenticationSession from a nonisolated (file-scope) context
/// so the completion closure doesn't inherit @MainActor isolation and crash
/// when the framework calls back on an XPC thread. (swiftlang/swift#75453)
private func launchWebAuthSession(url: URL, viewModel: AuthViewModel) {
    let ref = WeakRef(value: viewModel)
    let contextProvider = WebAuthContextProvider()
    let session = ASWebAuthenticationSession(
        url: url,
        callbackURLScheme: "therapyrecorder"
    ) { callbackURL, error in
        Task { @MainActor in
            ref.value?.handleAuthCallback(callbackURL: callbackURL, error: error)
        }
    }
    session.presentationContextProvider = contextProvider
    session.prefersEphemeralWebBrowserSession = false
    _ = contextProvider
    session.start()
}

// MARK: - ASWebAuthenticationPresentationContextProviding

private final class WebAuthContextProvider: NSObject, @preconcurrency ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // swiftlint:disable:next force_unwrapping
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first!
    }
}
