import SwiftUI

/// A small status dot with a label — used wherever a boolean state needs a visual indicator.
struct StatusIndicator: View {
    let isActive: Bool
    let activeLabel: String
    let inactiveLabel: String
    var activeColor: Color = .pabloSage
    var inactiveColor: Color = .pabloBlush

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isActive ? activeColor : inactiveColor)
                .frame(width: 8, height: 8)
            Text(isActive ? activeLabel : inactiveLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        StatusIndicator(isActive: true, activeLabel: "Connected", inactiveLabel: "Not connected")
        StatusIndicator(isActive: false, activeLabel: "Connected", inactiveLabel: "Not connected")
        StatusIndicator(
            isActive: false,
            activeLabel: "Granted",
            inactiveLabel: "Not Granted",
            inactiveColor: .pabloHoney
        )
    }
    .padding()
}
