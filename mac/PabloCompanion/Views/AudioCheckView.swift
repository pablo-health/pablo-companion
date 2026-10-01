import AppKit
import SwiftUI

/// "Say hello to Pablo": the under-a-minute first-use audio check.
struct AudioCheckView: View {
    @State private var model = AudioCheckViewModel()
    @State private var runTask: Task<Void, Never>?

    let micDeviceID: String?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image("PabloBear")
                .resizable()
                .scaledToFill()
                .frame(width: 96, height: 96)
                .clipShape(Circle())
                .accessibilityHidden(true)
            stepContent
            Spacer(minLength: 0)
            buttons
        }
        .padding(32)
        .frame(width: 440, height: 480)
        .background(Color.pabloCream)
        .onChange(of: model.step) { _, step in announce(step) }
        .onDisappear {
            runTask?.cancel()
            Task { await model.cancel() }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .intro:
            heading("Let’s make sure I can hear both sides of your sessions.")
            caption("This takes less than a minute.")
        case .greeting:
            heading("Listen for Pablo…")
            caption("“Hi, I’m Pablo. Welcome to Pablo Companion! Now say, hello Pablo, so I can hear you.”")
            checks
        case .yourTurn:
            heading("Your turn: say “Hello, Pablo”")
            checks
        case .done:
            result
        }
    }

    private var checks: some View {
        VStack(alignment: .leading, spacing: 10) {
            checkRow(
                done: model.heardComputer,
                text: "I can hear your computer. That’s how I’ll hear your client."
            )
            checkRow(done: model.heardYou, text: "I can hear you.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var result: some View {
        if let failure = model.startFailure {
            heading(failureTitle(failure))
            caption(failureAdvice(failure))
        } else if model.passed {
            heading("You’re all set.")
            caption("Pablo’s got it.")
            checks
        } else if !model.heardComputer {
            heading("I couldn’t hear your computer")
            caption("Turn your volume up and make sure Pablo is allowed System Audio Recording, then try again.")
            checks
        } else {
            heading("I couldn’t hear you")
            caption("Check that your microphone is connected and Pablo is allowed to use it, then try again.")
            checks
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private var buttons: some View {
        switch model.step {
        case .intro:
            HStack {
                Button("Do it later", action: onClose)
                    .accessibilityLabel("Skip the audio check for now")
                Spacer()
                primaryButton("Start") { start() }
                    .accessibilityLabel("Start the audio check")
            }
        case .greeting, .yourTurn:
            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                    .accessibilityLabel("Cancel the audio check")
            }
        case .done where model.passed:
            HStack {
                Spacer()
                primaryButton("Done", action: onClose)
                    .accessibilityLabel("Close the audio check")
            }
        case .done:
            HStack {
                Button("Do it later", action: onClose)
                    .accessibilityLabel("Close the audio check and try later")
                Spacer()
                if let url = settingsURL {
                    Button("Open Settings") { NSWorkspace.shared.open(url) }
                        .accessibilityLabel("Open privacy settings for Pablo")
                }
                primaryButton("Try again") { start() }
                    .accessibilityLabel("Run the audio check again")
            }
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .tint(Color.pabloHoney)
            .controlSize(.large)
    }

    private func start() {
        runTask?.cancel()
        runTask = Task { await model.run(micDeviceID: micDeviceID) }
    }

    // MARK: - Pieces

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.pabloDisplay(20))
            .foregroundStyle(Color.pabloBrownDeep)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.pabloBody(14))
            .foregroundStyle(Color.pabloBrownSoft)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func checkRow(done: Bool, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.pabloSage : Color.pabloBrownSoft)
                .accessibilityHidden(true)
            Text(text)
                .font(.pabloBody(14))
                .foregroundStyle(Color.pabloBrownDeep)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? "Done" : "Not yet")
    }

    private var settingsURL: URL? {
        if model.startFailure == .microphonePermission || (model.heardComputer && !model.heardYou) {
            return AudioCheckViewModel.microphoneSettingsURL
        }
        return ClientAudioWarningBanner.privacySettingsURL
    }

    private func failureTitle(_ failure: AudioCheckViewModel.StartFailure) -> String {
        switch failure {
        case .microphonePermission: "Pablo needs your microphone"
        case .systemAudioPermission: "Pablo needs to hear your computer"
        case .other: "Pablo couldn’t start listening"
        }
    }

    private func failureAdvice(_ failure: AudioCheckViewModel.StartFailure) -> String {
        switch failure {
        case .microphonePermission:
            "Allow Pablo in System Settings → Privacy & Security → Microphone, then try again."
        case .systemAudioPermission:
            "Allow Pablo in System Settings → Privacy & Security → Screen & System Audio Recording, then try again."
        case let .other(message):
            message
        }
    }

    private func announce(_ step: AudioCheckViewModel.Step) {
        let message = switch step {
        case .intro: ""
        case .greeting: "Listen for Pablo"
        case .yourTurn: "Your turn. Say hello, Pablo."
        case .done: model.passed ? "You’re all set" : "The audio check found a problem"
        }
        guard !message.isEmpty else { return }
        AccessibilityNotification.Announcement(message).post()
    }
}

#Preview {
    AudioCheckView(micDeviceID: nil, onClose: {})
}
