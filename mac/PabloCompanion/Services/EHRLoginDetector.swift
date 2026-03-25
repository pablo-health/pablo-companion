import Foundation
import os

/// Detects EHR login pages and waits for the therapist to sign in.
///
/// Checks for password fields, login-related URLs, and common login page text.
/// When detected, notifies the UI so the therapist can sign in manually.
/// Polls until the login page is gone (max 2 minutes).
enum EHRLoginDetector {
    private static let logger = Logger(
        subsystem: AppConstants.appBundleID, category: "EHRLoginDetector"
    )

    /// Waits for the therapist to sign in if a login page is detected.
    /// Returns immediately if already signed in.
    @MainActor
    static func waitForLogin(
        cdp: CDPConnection,
        ehrSystem: String,
        onPhaseChange: @escaping (SoapEntryPhase, String) -> Void,
        onLoginRequired: ((_ ehrSystem: String) async -> Bool)?
    ) async throws {
        let isLogin = try await detectLoginPage(cdp: cdp)
        guard isLogin else { return }

        logger.info("Login page detected for \(ehrSystem)")
        onPhaseChange(.navigating, "Please sign in to your EHR...")

        if let onLogin = onLoginRequired {
            let signedIn = await onLogin(ehrSystem)
            if !signedIn {
                throw EHRNavigatorError.actionFailed(
                    action: "login", selector: "Therapist declined to sign in"
                )
            }
        }

        // Poll until login page is gone (max 2 minutes)
        for _ in 1 ... 60 {
            try await Task.sleep(for: .seconds(2))
            let stillLogin = try await detectLoginPage(cdp: cdp)
            if !stillLogin {
                logger.info("Login complete for \(ehrSystem)")
                onPhaseChange(.navigating, "Signed in. Navigating...")
                try await Task.sleep(for: .seconds(1))
                return
            }
        }
        throw EHRNavigatorError.actionFailed(
            action: "login", selector: "Timed out waiting for EHR login"
        )
    }

    /// Checks if the current page looks like a login page.
    private static func detectLoginPage(cdp: CDPConnection) async throws -> Bool {
        let js = """
        (() => {
            const url = window.location.href.toLowerCase();
            const text = document.body?.innerText?.toLowerCase() || '';
            const hasPasswordField = !!document.querySelector('input[type="password"]');
            const urlHints = ['login', 'signin', 'sign-in', 'auth', 'sso'];
            const textHints = ['sign in', 'log in', 'username', 'forgot password'];
            const urlMatch = urlHints.some(h => url.includes(h));
            const textMatch = textHints.some(h => text.includes(h));
            return (hasPasswordField || urlMatch || textMatch) ? 'true' : 'false';
        })()
        """
        let result = try await cdp.evaluateJS(js)
        return result == "true"
    }
}
