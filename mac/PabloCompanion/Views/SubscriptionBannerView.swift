import SwiftUI

/// Subscription status banner displayed above the tab view.
///
/// Renders different states: trial info, past-due/canceled warnings with
/// Pablo Bear and a 1-day extension button, or a grace-active confirmation.
struct SubscriptionBannerView: View {
    var viewModel: SubscriptionViewModel

    var body: some View {
        switch viewModel.bannerState {
        case .hidden:
            EmptyView()
        case let .trial(sessionsRemaining, daysRemaining):
            trialBanner(sessionsRemaining: sessionsRemaining, daysRemaining: daysRemaining)
        case let .pastDue(extensionAvailable):
            lapsedBanner(
                heading: "Your payment needs attention",
                extensionAvailable: extensionAvailable
            )
        case let .canceled(extensionAvailable):
            lapsedBanner(
                heading: "Your subscription has ended",
                extensionAvailable: extensionAvailable
            )
        case let .graceActive(expiresAt):
            graceActiveBanner(expiresAt: expiresAt)
        }
    }

    // MARK: - Trial

    private func trialBanner(sessionsRemaining: Int?, daysRemaining: Int?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.pabloHoney)
                .accessibilityHidden(true)
            Text(trialText(sessionsRemaining: sessionsRemaining, daysRemaining: daysRemaining))
                .font(.pabloBody(13))
                .foregroundStyle(Color.pabloBrownDeep)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.pabloHoney.opacity(0.12))
    }

    private func trialText(sessionsRemaining: Int?, daysRemaining: Int?) -> String {
        var parts: [String] = []
        if let sessions = sessionsRemaining {
            parts.append("\(sessions) session\(sessions == 1 ? "" : "s") remaining")
        }
        if let days = daysRemaining {
            parts.append("\(days) day\(days == 1 ? "" : "s") left")
        }
        if parts.isEmpty {
            return "You're on a free trial"
        }
        return "Free trial — " + parts.joined(separator: ", ")
    }

    // MARK: - Past Due / Canceled

    private func lapsedBanner(heading: String, extensionAvailable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            lapsedHeader(heading: heading)
            lapsedActions(extensionAvailable: extensionAvailable)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.pabloBlush.opacity(0.15))
    }

    private func lapsedHeader(heading: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image("PabloBear")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Pablo Bear mascot")

            VStack(alignment: .leading, spacing: 4) {
                Text("Pablo doesn't want billing to get in the way of therapy")
                    .font(.pabloBody(13))
                    .fontWeight(.medium)
                    .foregroundStyle(Color.pabloBrownDeep)
                Text(heading)
                    .font(.pabloBody(12))
                    .foregroundStyle(Color.pabloBrownSoft)
            }
            Spacer()
        }
    }

    private func lapsedActions(extensionAvailable: Bool) -> some View {
        HStack(spacing: 12) {
            contactSupportButton
            if extensionAvailable {
                extensionButton
            }
            Spacer()
            if let error = viewModel.extensionError {
                Text(error)
                    .font(.pabloBody(11))
                    .foregroundStyle(Color.pabloError)
                    .lineLimit(1)
            }
        }
    }

    private var contactSupportButton: some View {
        Button {
            if let url = URL(string: "mailto:support@pablo.health") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Label("Contact Support", systemImage: "envelope")
                .font(.pabloBody(12))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel("Email Pablo support at support@pablo.health")
    }

    private var extensionButton: some View {
        Button {
            Task { await viewModel.requestExtension() }
        } label: {
            if viewModel.isExtending {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 14, height: 14)
            } else {
                Text("Get 1 More Day")
                    .font(.pabloBody(12))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.pabloHoney)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .disabled(viewModel.isExtending)
        .accessibilityLabel("Request one-day billing extension")
    }

    // MARK: - Grace Active

    private func graceActiveBanner(expiresAt: Date) -> some View {
        let timeLeft = expiresAt.formatted(.relative(presentation: .named))
        return HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.pabloSage)
                .accessibilityHidden(true)
            Text("You're covered through \(timeLeft) — take care of your sessions today")
                .font(.pabloBody(13))
                .foregroundStyle(Color.pabloBrownDeep)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.pabloSage.opacity(0.1))
    }
}

// MARK: - Previews

#Preview("Trial") {
    let vm = SubscriptionViewModel()
    vm.subscriptionInfo = SubscriptionInfo(
        status: .trial,
        plan: "solo",
        trialSessionsUsed: 12,
        trialSessionsLimit: 20,
        trialDaysLimit: 30,
        trialStart: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86400 * 15)),
        graceExtensionAvailable: false,
        graceExtensionExpiresAt: nil
    )
    return SubscriptionBannerView(viewModel: vm)
        .frame(width: 500)
        .background(Color.pabloCream)
}

#Preview("Past Due") {
    let vm = SubscriptionViewModel()
    vm.subscriptionInfo = SubscriptionInfo(
        status: .pastDue,
        plan: "solo",
        trialSessionsUsed: nil,
        trialSessionsLimit: nil,
        trialDaysLimit: nil,
        trialStart: nil,
        graceExtensionAvailable: true,
        graceExtensionExpiresAt: nil
    )
    return SubscriptionBannerView(viewModel: vm)
        .frame(width: 500)
        .background(Color.pabloCream)
}

#Preview("Canceled") {
    let vm = SubscriptionViewModel()
    vm.subscriptionInfo = SubscriptionInfo(
        status: .canceled,
        plan: "solo",
        trialSessionsUsed: nil,
        trialSessionsLimit: nil,
        trialDaysLimit: nil,
        trialStart: nil,
        graceExtensionAvailable: false,
        graceExtensionExpiresAt: nil
    )
    return SubscriptionBannerView(viewModel: vm)
        .frame(width: 500)
        .background(Color.pabloCream)
}

#Preview("Grace Active") {
    let vm = SubscriptionViewModel()
    vm.subscriptionInfo = SubscriptionInfo(
        status: .pastDue,
        plan: "solo",
        trialSessionsUsed: nil,
        trialSessionsLimit: nil,
        trialDaysLimit: nil,
        trialStart: nil,
        graceExtensionAvailable: false,
        graceExtensionExpiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600 * 18))
    )
    return SubscriptionBannerView(viewModel: vm)
        .frame(width: 500)
        .background(Color.pabloCream)
}

#Preview("Active - No Banner") {
    let vm = SubscriptionViewModel()
    vm.subscriptionInfo = SubscriptionInfo(
        status: .active,
        plan: "solo",
        trialSessionsUsed: nil,
        trialSessionsLimit: nil,
        trialDaysLimit: nil,
        trialStart: nil,
        graceExtensionAvailable: false,
        graceExtensionExpiresAt: nil
    )
    return SubscriptionBannerView(viewModel: vm)
        .frame(width: 500)
        .background(Color.pabloCream)
}
