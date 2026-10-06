import CompanionSessionCore
import SwiftUI

/// Affirmative confirmation shown when a session is handed off to the companion
/// from the web dashboard (or the legacy scheme). This is the consent gate:
/// **the microphone must not arm until the therapist explicitly taps
/// "Start Recording".** Never auto-start recording from an external trigger.
///
/// It also carries the client's answer about AI-assisted notes, when the
/// practice asks: a client who declined gets the declined message and no way
/// to arm; a client nobody has asked yet gets "Client agreed today", "Record
/// anyway" and "Cancel". A direct start from the companion's own window lands
/// here only in those two cases.
///
/// Presented as a sheet over whatever window is frontmost, matching how other
/// session surfaces (practice, transcript viewer) are presented today.
struct SessionConfirmationView: View {
    /// Non-PHI-leaking context for the pending handoff. `patientName` is PHI and
    /// is only rendered here; it is never logged.
    let patientName: String?

    /// The client's answer, as it bears on recording.
    var consent: RecordingConsent = .clear

    /// The answer is still being read; Start Recording waits for it.
    var isCheckingConsent = false

    /// "Client agreed today" is being saved.
    var isSavingConsent = false

    /// Shown when "Client agreed today" could not be saved.
    var consentError: String?

    /// The practice's audio retention window when it asks its clients; offers
    /// the read-aloud script. `nil` hides it.
    var scriptRetentionDays: Int?

    /// Invoked when the therapist taps "Start Recording" or "Record anyway".
    /// Only here (and after "Client agreed today" is saved) does the mic arm.
    let onStartRecording: () -> Void

    /// "Client agreed today": record the answer, then arm.
    var onAgreedToday: () -> Void = {}

    /// Opens the client's chart, where a declined answer can be changed.
    var onOpenChart: (() -> Void)?

    /// Invoked when the therapist dismisses without starting.
    let onCancel: () -> Void

    private var displayName: String {
        if let patientName, !patientName.isEmpty {
            return patientName
        }
        return "this patient"
    }

    var body: some View {
        Group {
            switch consent {
            case .clear:
                startContent
            case .notAsked:
                notAskedContent
            case let .declined(on):
                declinedContent(on: on)
            }
        }
        .padding(28)
        .frame(width: 360)
        .background(Color.pabloCream)
    }

    private var startContent: some View {
        VStack(spacing: 20) {
            header(
                icon: "waveform.badge.mic",
                title: "Start session with \(displayName)?",
                message: "Recording won't begin until you tap Start Recording."
            )
            script
            VStack(spacing: 10) {
                Button(action: onStartRecording) {
                    HStack(spacing: 8) {
                        if isCheckingConsent {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityHidden(true)
                        }
                        Text("Start Recording")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(isCheckingConsent)
                .accessibilityLabel("Start recording with \(displayName)")

                wideButton("Cancel", role: .cancel, action: onCancel)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Start session with \(displayName)")
    }

    private var notAskedContent: some View {
        VStack(spacing: 20) {
            header(
                icon: "questionmark.bubble",
                title: RecordingConsentCopy.notAskedTitle,
                message: RecordingConsentCopy.notAskedMessage
            )
            script
            if let consentError {
                ErrorMessageLabel(message: consentError)
            }
            VStack(spacing: 10) {
                Button(action: onAgreedToday) {
                    Text(isSavingConsent ? "Saving…" : "Client agreed today")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(isSavingConsent)
                .accessibilityLabel("Client agreed today, start recording")

                wideButton("Record anyway", action: onStartRecording)
                    .disabled(isSavingConsent)
                wideButton("Cancel", role: .cancel, action: onCancel)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(RecordingConsentCopy.notAskedTitle)
    }

    private func declinedContent(on isoDay: String) -> some View {
        VStack(spacing: 20) {
            header(
                icon: "mic.slash",
                title: RecordingConsentCopy.declinedTitle,
                message: RecordingConsentCopy.declined(on: isoDay)
            )
            VStack(spacing: 10) {
                if let onOpenChart {
                    wideButton("Open chart", action: onOpenChart)
                }
                Button(action: onCancel) {
                    Text("Close")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Close")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(RecordingConsentCopy.declinedTitle)
    }

    // MARK: - Pieces

    private func header(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(Color.pabloSage)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder
    private var script: some View {
        if let scriptRetentionDays {
            ConsentScriptDisclosure(retentionDays: scriptRetentionDays)
        }
    }

    private func wideButton(
        _ title: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Text(title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityLabel(title)
    }
}

#Preview("Setting off") {
    SessionConfirmationView(patientName: "Sam", onStartRecording: {}, onCancel: {})
}

#Preview("Not asked") {
    SessionConfirmationView(
        patientName: "Sam",
        consent: .notAsked,
        scriptRetentionDays: 365,
        onStartRecording: {},
        onCancel: {}
    )
}

#Preview("Declined") {
    SessionConfirmationView(
        patientName: "Sam",
        consent: .declined(on: "2026-09-01"),
        onStartRecording: {},
        onOpenChart: {},
        onCancel: {}
    )
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
