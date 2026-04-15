import Foundation
import os

/// Manages subscription status fetching and the one-time grace extension.
///
/// Follows the same pattern as `SessionViewModel` — thin orchestration layer
/// over `APIClient`, observable state drives `SubscriptionBannerView`.
@MainActor
@Observable
final class SubscriptionViewModel {
    // MARK: - State

    /// Current subscription info from the backend. Nil until first fetch completes.
    var subscriptionInfo: SubscriptionInfo?

    /// Whether a grace extension request is in flight.
    var isExtending = false

    /// User-facing error from the last extension attempt.
    var extensionError: String?

    // MARK: - Dependencies

    var backendURL = "https://api.pablo.health" {
        didSet {
            if URLValidator.validateScheme(backendURL) == nil {
                let token = apiClient.getToken
                apiClient = APIClient(baseURL: backendURL)
                apiClient.getToken = token
            }
        }
    }

    private var apiClient: APIClient
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "SubscriptionVM")

    init() {
        self.apiClient = APIClient()
    }

    // MARK: - Auth

    func configureAuth(getToken: @escaping @Sendable () async throws -> String) {
        apiClient.getToken = getToken
    }

    // MARK: - Fetch

    /// Fetches subscription status from the backend. Silently no-ops on failure
    /// (subscription banner is informational, not blocking).
    func refreshStatus() async {
        do {
            subscriptionInfo = try await apiClient.fetchSubscriptionStatus()
            logger.info("Subscription status: \(self.subscriptionInfo?.status.rawValue ?? "nil")")
        } catch {
            logger.warning("Failed to fetch subscription status: \(error.localizedDescription)")
        }
    }

    // MARK: - Grace Extension

    /// Requests a one-time 1-day extension. Updates local state on success.
    func requestExtension() async {
        isExtending = true
        extensionError = nil

        do {
            subscriptionInfo = try await apiClient.extendSubscription()
            logger.info("Grace extension granted")
        } catch let error as APIError {
            extensionError = switch error {
            case .serverError(statusCode: 409, _): "Extension already used"
            default: "Something went wrong. Please contact support@pablo.health"
            }
            logger.error("Failed to request extension: HTTP error")
        } catch {
            extensionError = "Network error — check your connection and try again"
            logger.error("Failed to request extension: \(error)")
        }

        isExtending = false
    }

    // MARK: - Computed State

    /// Drives the banner view. Pure function of `subscriptionInfo`.
    var bannerState: SubscriptionBannerState {
        guard let info = subscriptionInfo else { return .hidden }

        if let expiresDate = activeGraceExpiry(info) {
            return .graceActive(expiresAt: expiresDate)
        }

        switch info.status {
        case .active:
            return .hidden
        case .trial:
            return .trial(
                sessionsRemaining: trialSessionsRemaining,
                daysRemaining: trialDaysRemaining
            )
        case .pastDue:
            return .pastDue(extensionAvailable: info.graceExtensionAvailable)
        case .canceled:
            return .canceled(extensionAvailable: info.graceExtensionAvailable)
        }
    }

    /// Sessions remaining in trial, or nil if not applicable.
    var trialSessionsRemaining: Int? {
        guard let info = subscriptionInfo,
              let used = info.trialSessionsUsed,
              let limit = info.trialSessionsLimit
        else { return nil }
        return max(0, limit - used)
    }

    /// Days remaining in trial, or nil if not applicable.
    var trialDaysRemaining: Int? {
        guard let info = subscriptionInfo,
              let startString = info.trialStart,
              let startDate = parseISO8601(startString),
              let daysLimit = info.trialDaysLimit
        else { return nil }
        let elapsed = Calendar.current.dateComponents([.day], from: startDate, to: Date()).day ?? 0
        return max(0, daysLimit - elapsed)
    }

    // MARK: - Helpers

    /// Returns the grace expiry date if the extension is currently active, nil otherwise.
    private func activeGraceExpiry(_ info: SubscriptionInfo) -> Date? {
        guard let expiresString = info.graceExtensionExpiresAt,
              let expiresDate = parseISO8601(expiresString),
              expiresDate > Date() else { return nil }
        return expiresDate
    }

    private func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        // Retry without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
