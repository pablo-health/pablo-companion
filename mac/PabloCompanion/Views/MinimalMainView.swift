import SwiftUI

/// The thin-client main window (shown when `enableNativeDashboard` is false).
///
/// The web app is the dashboard; this window exists only to show connection
/// status, hand the user back to the web dashboard, and expose account /
/// preferences / version in a footer. Sized ~480×360 to be glanced at, not
/// lived in. No tabs, no session/patient lists.
struct MinimalMainView: View {
    let email: String
    let webDashboardURL: URL
    let isBackendReachable: Bool
    let micReady: Bool
    let appVersion: String
    let onOpenDashboard: () -> Void
    let onOpenPreferences: () -> Void
    let onSignOut: () -> Void

    /// Host shown in the status line, derived from the dashboard URL.
    private var host: String {
        webDashboardURL.host ?? "Pablo"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            header
            statusBlock
                .padding(.top, 18)
            Spacer(minLength: 16)
            Button(action: onOpenDashboard) {
                Label("Open Web Dashboard", systemImage: "safari")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 32)
            Spacer(minLength: 16)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.pabloCream)
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("Pablo Companion")
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.pabloBrownDeep)
            Text("Recording runs here. Your day lives on the web dashboard.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusRow(
                ok: isBackendReachable,
                okText: "Connected to \(host) as \(email)",
                offText: "Not connected to \(host)"
            )
            statusRow(
                ok: micReady,
                okText: "Microphone ready",
                offText: "Microphone permission needed"
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.5))
        )
        .padding(.horizontal, 32)
    }

    private func statusRow(ok: Bool, okText: String, offText: String) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(ok ? Color.pabloSage : Color.pabloError)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(ok ? okText : offText)
                .font(.subheadline)
                .foregroundStyle(Color.pabloBrownDeep)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Button("Preferences", action: onOpenPreferences)
                .buttonStyle(.link)
            Button("Sign Out", role: .destructive, action: onSignOut)
                .buttonStyle(.link)
            Spacer()
            Text("v\(appVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Version \(appVersion)")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.35))
    }
}
