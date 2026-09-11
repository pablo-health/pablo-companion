import SwiftUI

/// A vertical audio level meter.
struct LevelMeter: View {
    let label: String
    let level: Float

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(levelColor)
                        .frame(
                            height: max(
                                0,
                                geometry.size.height * CGFloat(clampedLevel)
                            )
                        )
                }
            }
            .frame(width: 24)

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) audio level")
        .accessibilityValue(String(format: "%.0f percent", clampedLevel * 100))
    }

    private var clampedLevel: Float {
        min(max(level, 0), 1)
    }

    private var levelColor: Color {
        if clampedLevel > 0.8 {
            .pabloBlush
        } else if clampedLevel > 0.5 {
            .pabloHoney
        } else {
            .pabloSage
        }
    }
}

#Preview {
    HStack(spacing: 24) {
        LevelMeter(label: "Mic", level: 0.65)
        LevelMeter(label: "Sys", level: 0.3)
    }
    .frame(height: 100)
    .padding()
}
