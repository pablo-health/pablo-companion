import Foundation

enum AppConstants {
    static let appBundleID = Bundle.main.bundleIdentifier ?? "health.pablo.companion"
    static let keychainAccessGroup = "L8KG4FA2R9.\(appBundleID)"
    /// App version from Info.plist (CFBundleShortVersionString), e.g. "1.0.0".
    static let appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
}
