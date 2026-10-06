import CompanionSessionCore
import SwiftUI

/// "Consent script": the words to read aloud before recording, the same ones
/// the web app shows. Collapsed until asked for, so the confirmation stays
/// short for a clinician who already knows them.
struct ConsentScriptDisclosure: View {
    /// The practice's audio retention window, read aloud in the script.
    let retentionDays: Int

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                Label(
                    RecordingConsentCopy.scriptTitle,
                    systemImage: isExpanded ? "chevron.down" : "chevron.right"
                )
                .font(.subheadline)
            }
            .buttonStyle(.link)
            .accessibilityLabel(RecordingConsentCopy.scriptTitle)
            .accessibilityValue(isExpanded ? "Shown" : "Hidden")

            if isExpanded {
                Text(RecordingConsentCopy.scriptPrompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                scriptLines
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var scriptLines: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ConsentScript.lines(retentionDays: retentionDays), id: \.self) { line in
                Text(line)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.pabloSage.opacity(0.5))
                .frame(width: 2)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ConsentScriptDisclosure(retentionDays: 365)
        .padding()
        .frame(width: 360)
}
