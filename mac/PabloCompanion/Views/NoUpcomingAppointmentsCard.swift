import SwiftUI

/// Shown in the minimal window once nothing is left on today's schedule —
/// either the day is clear or every appointment has already been seen.
struct NoUpcomingAppointmentsCard: View {
    private enum Layout {
        static let bearSize: CGFloat = 72
    }

    let cornerRadius: CGFloat

    var body: some View {
        HStack(spacing: 16) {
            Image("PabloBear")
                .resizable()
                .scaledToFill()
                .frame(width: Layout.bearSize, height: Layout.bearSize)
                .clipShape(Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("No upcoming appointments for today")
                    .font(.pabloDisplay(16))
                    .foregroundStyle(Color.pabloBrownDeep)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Pablo’s got it.")
                    .font(.pabloBody(13))
                    .foregroundStyle(Color.pabloBrownSoft)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.pabloSage.opacity(0.12))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No upcoming appointments for today")
    }
}

#Preview {
    NoUpcomingAppointmentsCard(cornerRadius: 12)
        .padding(32)
        .frame(width: 520)
        .background(Color.pabloCream)
}
