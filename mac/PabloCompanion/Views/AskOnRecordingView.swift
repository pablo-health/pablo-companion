import CompanionSessionCore
import SwiftUI

/// Shown once recording has started for a telehealth client nobody had asked
/// about AI-assisted notes: the script to read aloud, so the answer is on the
/// recording, and the answer to save on the client's record.
struct AskOnRecordingView: View {
    @Bindable var viewModel: AskOnRecordingViewModel

    /// Save the client's answer.
    let onAnswer: (_ decision: String) -> Void

    /// Close without saving an answer here.
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(RecordingConsentCopy.askingTitle)
                .font(.title3.weight(.semibold))

            if viewModel.recordingDeleted {
                Text(RecordingConsentCopy.recordingDeleted)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                askContent
            }

            if let saveError = viewModel.saveError {
                ErrorMessageLabel(message: saveError)
            }

            buttons
        }
        .padding(28)
        .frame(width: 400)
        .background(Color.pabloCream)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(RecordingConsentCopy.askingTitle)
    }

    @ViewBuilder
    private var askContent: some View {
        if let retentionDays = viewModel.ask?.retentionDays {
            Text(RecordingConsentCopy.askingPrompt)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ConsentScriptLines(retentionDays: retentionDays)
        }

        if viewModel.ask?.patientId != nil {
            answerControls
        } else {
            Text(RecordingConsentCopy.recordOnChart)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var answerControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ConsentGiverPicker(giver: $viewModel.giver)
            VStack(alignment: .leading, spacing: 4) {
                Text(RecordingConsentCopy.locationLabel)
                    .font(.subheadline)
                TextField(RecordingConsentCopy.locationLabel, text: $viewModel.location)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .accessibilityLabel(RecordingConsentCopy.locationLabel)
                    .onChange(of: viewModel.location) { _, value in
                        if value.count > AiConsentAnswer.locationMaxLength {
                            viewModel.location = String(value.prefix(AiConsentAnswer.locationMaxLength))
                        }
                    }
            }
        }
        .disabled(viewModel.isSaving)
    }

    private var buttons: some View {
        VStack(spacing: 10) {
            if viewModel.recordingDeleted {
                // Only a decline that could not be saved is left to do.
                if viewModel.saveError != nil {
                    let declined = RecordingConsentCopy.answered(AiConsentEntry.declined, by: viewModel.giver)
                    wideButton(declined) { onAnswer(AiConsentEntry.declined) }
                        .disabled(viewModel.isSaving)
                }
            } else if viewModel.ask?.patientId != nil {
                let agreed = RecordingConsentCopy.answered(AiConsentEntry.consented, by: viewModel.giver)
                Button { onAnswer(AiConsentEntry.consented) } label: {
                    Text(viewModel.isSaving ? "Saving…" : agreed)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(viewModel.isSaving)
                .accessibilityLabel(agreed)

                let declined = RecordingConsentCopy.answered(AiConsentEntry.declined, by: viewModel.giver)
                wideButton(declined) { onAnswer(AiConsentEntry.declined) }
                    .disabled(viewModel.isSaving)
            }
            wideButton("Close", action: onClose)
                .disabled(viewModel.isSaving)
        }
    }

    private func wideButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityLabel(title)
    }
}

#Preview {
    let viewModel = AskOnRecordingViewModel()
    viewModel.begin(sessionId: "s1", patientId: "p1", retentionDays: 0)
    return AskOnRecordingView(viewModel: viewModel, onAnswer: { _ in }, onClose: {})
}
