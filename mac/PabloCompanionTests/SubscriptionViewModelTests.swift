import Foundation
@testable import Pablo
import Testing

@Suite("SubscriptionViewModel trial limits")
@MainActor
struct SubscriptionViewModelTrialTests {

    // MARK: - trialSessionsRemaining

    @Test func sessionsRemaining_normalLimit() {
        let vm = SubscriptionViewModel()
        vm.subscriptionInfo = makeInfo(sessionsUsed: 8, sessionsLimit: 20)
        #expect(vm.trialSessionsRemaining == 12)
    }

    @Test func sessionsRemaining_zeroLimitIsUnlimited() {
        // Backend contract: trial_sessions_limit=0 means no session cap.
        let vm = SubscriptionViewModel()
        vm.subscriptionInfo = makeInfo(sessionsUsed: 5, sessionsLimit: 0)
        #expect(vm.trialSessionsRemaining == nil, "limit=0 must return nil (unlimited), not 0")
    }

    @Test func sessionsRemaining_nilLimitReturnsNil() {
        let vm = SubscriptionViewModel()
        vm.subscriptionInfo = makeInfo(sessionsUsed: 3, sessionsLimit: nil)
        #expect(vm.trialSessionsRemaining == nil)
    }

    @Test func sessionsRemaining_clampedToZero() {
        let vm = SubscriptionViewModel()
        vm.subscriptionInfo = makeInfo(sessionsUsed: 25, sessionsLimit: 20)
        #expect(vm.trialSessionsRemaining == 0)
    }

    // MARK: - trialDaysRemaining

    @Test func daysRemaining_normalLimit() throws {
        let vm = SubscriptionViewModel()
        vm.subscriptionInfo = makeInfo(
            daysLimit: 30,
            trialStart: iso8601(daysAgo: 10)
        )
        let remaining = vm.trialDaysRemaining
        #expect(remaining != nil)
        #expect(try #require(remaining) >= 19 && remaining! <= 20, "Expected ~20 days remaining")
    }

    @Test func daysRemaining_zeroLimitIsUnlimited() {
        // Backend contract: trial_days_limit=0 means no time cap.
        let vm = SubscriptionViewModel()
        vm.subscriptionInfo = makeInfo(
            daysLimit: 0,
            trialStart: iso8601(daysAgo: 10)
        )
        #expect(vm.trialDaysRemaining == nil, "daysLimit=0 must return nil (unlimited), not 0")
    }

    @Test func daysRemaining_nilLimitReturnsNil() {
        let vm = SubscriptionViewModel()
        vm.subscriptionInfo = makeInfo(daysLimit: nil, trialStart: iso8601(daysAgo: 5))
        #expect(vm.trialDaysRemaining == nil)
    }

    // MARK: - bannerState with limit=0

    @Test func bannerState_unlimitedSessionsAndDays_showsGenericTrialText() {
        let vm = SubscriptionViewModel()
        vm.subscriptionInfo = makeInfo(
            sessionsUsed: 5, sessionsLimit: 0,
            daysLimit: 0, trialStart: iso8601(daysAgo: 10)
        )
        if case let .trial(sessions, days) = vm.bannerState {
            #expect(sessions == nil, "Unlimited sessions must be nil in banner state")
            #expect(days == nil, "Unlimited days must be nil in banner state")
        } else {
            Issue.record("Expected .trial banner state")
        }
    }

    // MARK: - Helpers

    private func makeInfo(
        sessionsUsed: Int? = nil,
        sessionsLimit: Int? = nil,
        daysLimit: Int? = nil,
        trialStart: String? = nil
    ) -> SubscriptionInfo {
        SubscriptionInfo(
            status: .trial,
            plan: "solo",
            trialSessionsUsed: sessionsUsed,
            trialSessionsLimit: sessionsLimit,
            trialDaysLimit: daysLimit,
            trialStart: trialStart,
            graceExtensionAvailable: false,
            graceExtensionExpiresAt: nil
        )
    }

    private func iso8601(daysAgo: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date().addingTimeInterval(-86400 * daysAgo))
    }
}
