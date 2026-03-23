import SwiftUI

/// "Send to EHR" button and progress UI, shown on the session detail view
/// when a SOAP note is available.
struct SendToEHRView: View {
    @Bindable var viewModel: EHREntryViewModel
    let soapNote: SoapNoteContent
    let patientFirstName: String
    let patientLastName: String
    let appointmentDate: String
    let appointmentTime: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            HStack {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(Color.pabloHoney)
                Text("Send to EHR")
                    .font(.pabloHeading(15))
                    .foregroundStyle(Color.pabloBrownDeep)
            }

            switch viewModel.state {
            case .idle:
                idleView
            case let .navigating(step, description):
                navigatingView(step: step, description: description)
            case .identifying:
                identifyingView
            case .confirming:
                confirmingView
            case let .filling(section):
                fillingView(section: section)
            case .completed:
                completedView
            case let .error(message):
                errorView(message: message)
            case let .askingHuman(question):
                askingHumanView(question: question)
            }
        }
        .padding(16)
        .background(Color.pabloCreamDark.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - State Views

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SOAP note is ready. Open your EHR to the patient's page, then click below.")
                .font(.pabloBody(13))
                .foregroundStyle(Color.pabloBrownSoft)

            Button {
                Task {
                    await viewModel.startEntry(
                        soapNote: soapNote,
                        patientFirstName: patientFirstName,
                        patientLastName: patientLastName,
                        appointmentDate: appointmentDate,
                        appointmentTime: appointmentTime
                    )
                }
            } label: {
                HStack {
                    Image(systemName: "arrow.up.doc.fill")
                    Text(viewModel.ehrDisplayName.map { "Send to \($0)" } ?? "Send to EHR")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.pabloHoney)
            .accessibilityLabel("Send SOAP note to EHR for \(patientFirstName) \(patientLastName)")
        }
    }

    private func navigatingView(step: Int, description: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Navigating to \(patientFirstName) \(patientLastName)...")
                    .font(.pabloBody(13))
                    .foregroundStyle(Color.pabloBrownDeep)
                Text(description)
                    .font(.pabloCaption(11))
                    .foregroundStyle(Color.pabloBrownSoft)
                Text("Step \(step + 1) of \(viewModel.maxNavigationSteps)")
                    .font(.pabloCaption(11))
                    .foregroundStyle(Color.pabloBrownSoft)
            }
            Spacer()
            cancelButton
        }
    }

    private var identifyingView: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Identifying SOAP fields...")
                .font(.pabloBody(13))
                .foregroundStyle(Color.pabloBrownDeep)
            Spacer()
            cancelButton
        }
    }

    private var confirmingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Please confirm these field mappings:")
                .font(.pabloBody(13))
                .foregroundStyle(Color.pabloBrownDeep)

            ForEach(viewModel.identifiedFields) { field in
                FieldConfirmationRow(
                    field: field,
                    onCorrect: { viewModel.correctField(section: field.soapSection) }
                )
            }

            HStack {
                Button("Confirm & Fill") {
                    Task { await viewModel.confirmFields() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.pabloSage)
                .accessibilityLabel("Confirm field mappings and fill SOAP note")

                cancelButton
            }
        }
    }

    private func fillingView(section: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Filling \(section)...")
                .font(.pabloBody(13))
                .foregroundStyle(Color.pabloBrownDeep)
            Spacer()
        }
    }

    private var completedView: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.pabloSage)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("SOAP note sent!")
                    .font(.pabloBody(13))
                    .foregroundStyle(Color.pabloBrownDeep)
                Text("All fields filled in \(viewModel.ehrDisplayName ?? "your EHR").")
                    .font(.pabloCaption(11))
                    .foregroundStyle(Color.pabloBrownSoft)
            }
            Spacer()
            Button("Done") { viewModel.cancel() }
                .buttonStyle(.bordered)
                .accessibilityLabel("Dismiss EHR entry confirmation")
        }
    }

    private func errorView(message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.pabloTerracotta)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't send note")
                    .font(.pabloBody(13))
                    .foregroundStyle(Color.pabloBrownDeep)
                Text(message)
                    .font(.pabloCaption(11))
                    .foregroundStyle(Color.pabloBrownSoft)
            }
            Spacer()
            Button("Try Again") {
                Task {
                    await viewModel.startEntry(
                        soapNote: soapNote,
                        patientFirstName: patientFirstName,
                        patientLastName: patientLastName,
                        appointmentDate: appointmentDate,
                        appointmentTime: appointmentTime
                    )
                }
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Retry sending SOAP note to EHR")
        }
    }

    private func askingHumanView(question: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(Color.pabloHoney)
                    .font(.title2)
                Text("Pablo needs your help")
                    .font(.pabloBody(13))
                    .foregroundStyle(Color.pabloBrownDeep)
            }
            Text(question)
                .font(.pabloBody(13))
                .foregroundStyle(Color.pabloBrownSoft)
            HStack {
                Button("I'm on the right page now") {
                    Task { await viewModel.answerAgent(response: "ready") }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.pabloHoney)
                .accessibilityLabel("Tell Pablo you've navigated to the correct page")

                cancelButton
            }
        }
    }

    private var cancelButton: some View {
        Button("Cancel") { viewModel.cancel() }
            .buttonStyle(.bordered)
            .accessibilityLabel("Cancel EHR note entry")
    }
}

// MARK: - Field Confirmation Row

struct FieldConfirmationRow: View {
    let field: IdentifiedField
    let onCorrect: () -> Void

    var body: some View {
        HStack {
            Image(systemName: field.confirmed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(field.confirmed ? Color.pabloSage : Color.pabloBrownSoft)

            VStack(alignment: .leading, spacing: 1) {
                Text(field.soapSection)
                    .font(.pabloBody(13))
                    .foregroundStyle(Color.pabloBrownDeep)
                Text(field.elementLabel)
                    .font(.pabloCaption(11))
                    .foregroundStyle(Color.pabloBrownSoft)
            }

            Spacer()

            if field.confidence > 0 {
                confidenceBadge
            }

            Button("Correct") { onCorrect() }
                .buttonStyle(.borderless)
                .font(.pabloCaption(11))
                .foregroundStyle(Color.pabloHoney)
                .accessibilityLabel("Correct the \(field.soapSection) field mapping")
        }
        .padding(.vertical, 4)
    }

    private var confidenceBadge: some View {
        Text("\(Int(field.confidence * 100))%")
            .font(.pabloCaption(10))
            .foregroundStyle(field.confidence >= 0.9 ? Color.pabloSage : Color.pabloHoney)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(field.confidence >= 0.9 ? Color.pabloSage.opacity(0.15) : Color.pabloHoney.opacity(0.15))
            )
    }
}
