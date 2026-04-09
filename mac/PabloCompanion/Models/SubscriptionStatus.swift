import Foundation

/// Wrapper for the `GET /api/users/me/status` response.
/// The `subscription` field is nil when the backend is not running in SaaS mode.
struct SubscriptionResponse: Codable, Sendable {
    let subscription: SubscriptionInfo?
}

/// Subscription details returned by the backend.
struct SubscriptionInfo: Codable, Sendable, Equatable {
    let status: SubscriptionState
    let plan: String
    let trialSessionsUsed: Int?
    let trialSessionsLimit: Int?
    let trialDaysLimit: Int?
    let trialStart: String?
    let graceExtensionAvailable: Bool
    let graceExtensionExpiresAt: String?
}

/// Subscription lifecycle states driven by the backend.
enum SubscriptionState: String, Codable, Sendable {
    case active
    case trial
    case pastDue = "past_due"
    case canceled
}

/// What the banner view should render. Computed from `SubscriptionInfo`.
enum SubscriptionBannerState: Equatable {
    case hidden
    case trial(sessionsRemaining: Int?, daysRemaining: Int?)
    case pastDue(extensionAvailable: Bool)
    case canceled(extensionAvailable: Bool)
    case graceActive(expiresAt: Date)
}
