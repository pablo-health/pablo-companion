import AppKit
import SwiftUI

/// Shown inside the recording card when the therapist is talking but nothing
/// is arriving from the call (`ClientAudioMonitor.Status.noClientAudio`).
///
/// Non-blocking: recording carries on either way. The two likely causes on a
/// working setup are the call's audio playing somewhere this Mac can't capture
/// and the System Audio Recording permission, so it names both and links
/// straight to the permission.
struct ClientAudioWarningBanner: View {
    static let privacySettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")

    private static let advice = "If your client is talking, make sure the call’s audio is playing "
        + "on this Mac and that Pablo is allowed System Audio Recording."

    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "speaker.slash.fill")
                .font(.title3)
                .foregroundStyle(Color.pabloError)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Pablo can’t hear your client yet")
                    .font(.pabloBody(13).weight(.semibold))
                    .foregroundStyle(Color.pabloBrownDeep)
                Text(Self.advice)
                    .font(.pabloBody(12))
                    .foregroundStyle(Color.pabloBrownSoft)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings") {
                    if let url = Self.privacySettingsURL {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .accessibilityLabel("Open System Audio Recording settings")
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.pabloBrownSoft)
            .accessibilityLabel("Dismiss client audio warning")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.pabloError.opacity(0.1))
        )
        .accessibilityElement(children: .contain)
        .onAppear {
            AccessibilityNotification.Announcement("Pablo can’t hear your client yet").post()
        }
    }
}

#Preview {
    ClientAudioWarningBanner(onDismiss: {})
        .padding()
        .frame(width: 456)
        .background(Color.pabloCream)
}
