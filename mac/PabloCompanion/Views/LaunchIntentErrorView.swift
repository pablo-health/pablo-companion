import SwiftUI

/// Shown when a launch intent could not be redeemed (expired, already used, or
/// an error). Carries no PHI — only an opaque, non-identifying message.
struct LaunchIntentErrorView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(message)
                .font(.headline)
                .multilineTextAlignment(.center)

            Button("OK", action: onDismiss)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 340)
        .background(Color.pabloCream)
    }
}

#Preview {
    LaunchIntentErrorView(message: "This link has expired — start again from the dashboard.", onDismiss: {})
}
