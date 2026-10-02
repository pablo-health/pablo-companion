import SwiftUI

/// A one-line note that one of today's sessions is being recorded somewhere
/// other than this Mac. Informational only: it never replaces the appointment
/// card, so it can't block the next Start Session.
struct InProgressElsewhereNote: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "record.circle")
                .foregroundStyle(Color.pabloSage)
                .accessibilityHidden(true)
            Text("Recording on another device: \(title.isEmpty ? "a session" : title)")
                .font(.pabloBody(12))
                .foregroundStyle(Color.pabloBrownSoft)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.pabloSage.opacity(0.1))
        )
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    InProgressElsewhereNote(title: "Initial consultation")
        .padding()
        .frame(width: 456)
        .background(Color.pabloCream)
}
