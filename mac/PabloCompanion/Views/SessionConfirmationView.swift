import SwiftUI

/// Affirmative confirmation shown when a session is handed off to the companion
/// from the web dashboard (or the legacy scheme). This is the consent gate:
/// **the microphone must not arm until the therapist explicitly taps
/// "Start Recording".** Never auto-start recording from an external trigger.
///
/// Presented as a sheet over whatever window is frontmost, matching how other
/// session surfaces (practice, transcript viewer) are presented today.
struct SessionConfirmationView: View {
    /// Non-PHI-leaking context for the pending handoff. `patientName` is PHI and
    /// is only rendered here; it is never logged.
    let patientName: String?

    /// Invoked when the therapist taps "Start Recording". Only here does the mic arm.
    let onStartRecording: () -> Void

    /// Invoked when the therapist dismisses without starting.
    let onCancel: () -> Void

    private var displayName: String {
        if let patientName, !patientName.isEmpty {
            return patientName
        }
        return "this patient"
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 44))
                .foregroundStyle(Color.pabloSage)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("Start session with \(displayName)?")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text("Recording won't begin until you tap Start Recording.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                Button(action: onStartRecording) {
                    Text("Start Recording")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
        }
        .padding(28)
        .frame(width: 360)
        .background(Color.pabloCream)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Start session with \(displayName)")
    }
}

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
