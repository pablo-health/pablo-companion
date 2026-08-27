import Foundation

enum AppConstants {
    static let appBundleID = Bundle.main.bundleIdentifier ?? "health.pablo.companion"
    static let keychainAccessGroup = "L8KG4FA2R9.\(appBundleID)"
    /// App version from Info.plist (CFBundleShortVersionString), e.g. "1.0.0".
    static let appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"

    /// Where a therapist signs in, unless they have saved an override.
    ///
    /// Named here rather than inlined at the point of use so the login screen
    /// can tell "the default" from "a self-hoster's saved server" and only show
    /// the URL field for the latter. Mirrors the Windows
    /// `AppConstants.DefaultAuthServerUrl`.
    static let defaultAuthServerURL = "https://app.pablo.health"

    /// The backend the app talks to until `/api/config` says otherwise.
    ///
    /// This is `app.pablo.health`, the same host as sign-in — `api.pablo.health`
    /// was hardcoded here and in six view models and does not resolve at all.
    /// Nothing noticed because config discovery replaces it before the first
    /// real call; the cost was that every pre-discovery fallback pointed at a
    /// host that does not exist.
    static let defaultBackendAPIURL = "https://app.pablo.health"
}
