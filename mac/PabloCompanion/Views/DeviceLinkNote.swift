import SwiftUI

/// Shown when sign-in could not register this Mac with the server. Until it
/// is registered the web dashboard offers the download instead of starting a
/// session here, which otherwise looks like the app was never installed.
struct DeviceLinkNote: View {
    let isRetrying: Bool
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "link.badge.plus")
                .font(.title3)
                .foregroundStyle(Color.pabloError)
                .accessibilityHidden(true)
            Text("This Mac isn't connected to your Pablo account yet, so the web dashboard can't start sessions here.")
                .font(.pabloBody(13))
                .foregroundStyle(Color.pabloBrownDeep)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if isRetrying {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Connecting this Mac")
            } else {
                Button("Try Again", action: onRetry)
                    .accessibilityLabel("Try connecting this Mac again")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.pabloError.opacity(0.1))
        )
        .accessibilityElement(children: .contain)
    }
}

extension MinimalMainView {
    @ViewBuilder var deviceLinkNote: some View {
        if deviceLinkFailed {
            DeviceLinkNote(isRetrying: isRelinkingDevice, onRetry: onRetryDeviceLink)
                .padding(.horizontal, Layout.pageInset)
                .padding(.top, 10)
        }
    }
}

#Preview("Not connected") {
    DeviceLinkNote(isRetrying: false, onRetry: {})
        .padding()
        .frame(width: 456)
        .background(Color.pabloCream)
}

#Preview("Retrying") {
    DeviceLinkNote(isRetrying: true, onRetry: {})
        .padding()
        .frame(width: 456)
        .background(Color.pabloCream)
}
