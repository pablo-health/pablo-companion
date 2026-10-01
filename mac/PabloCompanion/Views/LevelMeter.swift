import SwiftUI

/// A vertical audio level meter.
///
/// `level` is the linear RMS AudioCaptureKit reports (0–1). Drawn linearly,
/// speech — RMS around 0.01–0.1 — filled only a few percent of the bar and the
/// meter looked dead mid-session. It is shown on a decibel scale instead, as
/// audio meters conventionally are.
struct LevelMeter: View {
    /// Quietest level that registers; anything below reads as empty.
    nonisolated static let floorDecibels: Float = -60

    let label: String
    let level: Float

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(levelColor)
                        .frame(height: geometry.size.height * CGFloat(fraction))
                }
            }
            .frame(width: 24)
            .animation(reduceMotion ? nil : .linear(duration: 0.08), value: fraction)

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) audio level")
        .accessibilityValue(String(format: "%.0f percent", fraction * 100))
    }

    private var fraction: Float {
        Self.displayFraction(forRMS: level)
    }

    /// Maps linear RMS onto the bar: `floorDecibels` dBFS and below → 0,
    /// 0 dBFS → 1, linear in decibels between.
    nonisolated static func displayFraction(forRMS rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(min(rms, 1))
        return min(max((decibels - floorDecibels) / -floorDecibels, 0), 1)
    }

    /// Thresholds sit near the top of the decibel scale: normal speech lands
    /// mid-bar in sage, honey from about −12 dBFS, blush from −6 dBFS (close
    /// to clipping).
    private var levelColor: Color {
        if fraction > 0.9 {
            .pabloBlush
        } else if fraction > 0.8 {
            .pabloHoney
        } else {
            .pabloSage
        }
    }
}

#Preview {
    HStack(spacing: 24) {
        // Typical speech (~−30 dBFS) and a quiet far-end voice (~−45 dBFS).
        LevelMeter(label: "Mic", level: 0.03)
        LevelMeter(label: "Sys", level: 0.006)
        LevelMeter(label: "Loud", level: 0.4)
    }
    .frame(height: 100)
    .padding()
}
