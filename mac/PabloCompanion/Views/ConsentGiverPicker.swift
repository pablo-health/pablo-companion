import CompanionSessionCore
import SwiftUI

/// "Answered by": the client, or a parent or guardian answering for them.
struct ConsentGiverPicker: View {
    @Binding var giver: AiConsentGiver

    var body: some View {
        Picker(RecordingConsentCopy.answeredBy, selection: $giver) {
            ForEach(AiConsentGiver.allCases) { giver in
                Text(giver.word).tag(giver)
            }
        }
        .pickerStyle(.menu)
        .accessibilityLabel(RecordingConsentCopy.answeredBy)
        .accessibilityValue(giver.word)
    }
}

#Preview {
    ConsentGiverPicker(giver: .constant(.parent))
        .padding()
        .frame(width: 300)
}
