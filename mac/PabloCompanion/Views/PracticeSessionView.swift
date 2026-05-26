import PracticeClientCore
import SwiftUI

/// Main practice session UI — shows Pablo Bear, waveform, timer, and controls.
struct PracticeSessionView: View {
    let topic: PracticeTopic
    let duration: TimeInterval
    let micLevel: Float
    let pabloLevel: Float
    let pabloState: PracticeWebSocketClient.PabloState
    let isConnecting: Bool
    let onPause: () -> Void
    let onResume: () -> Void
    let onEnd: () -> Void

    @State private var isPaused = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            pabloBearSection
            waveformSection
            infoSection

            Spacer()

            controlsSection
        }
        .padding(32)
        .frame(minWidth: 400, minHeight: 480)
        .background(Color.pabloCream)
    }

    // MARK: - Pablo Bear

    private var pabloBearSection: some View {
        ZStack {
            // Glow when Pablo is speaking
            if pabloState == .speaking {
                Circle()
                    .fill(Color.pabloHoney.opacity(0.15))
                    .frame(width: 160, height: 160)
                    .blur(radius: reduceMotion ? 0 : 8)
            }

            Image(systemName: "pawprint.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.pabloHoney)
                .accessibilityHidden(true)
        }
        .frame(height: 140)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pablo Bear, \(pabloStateLabel)")
        .accessibilityValue(pabloStateLabel)
    }

    // MARK: - Waveform

    private var waveformSection: some View {
        VStack(spacing: 8) {
            // Pablo's waveform
            WaveformBar(level: pabloLevel, color: Color.pabloHoney, label: "Pablo")

            // Therapist's waveform
            WaveformBar(level: micLevel, color: Color.pabloSage, label: "You")
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Info

    private var infoSection: some View {
        VStack(spacing: 6) {
            Text(topic.name)
                .font(.pabloBody(14).weight(.medium))
                .foregroundStyle(Color.pabloBrownDeep)

            Text(formattedDuration)
                .font(.pabloBody(28).monospacedDigit())
                .foregroundStyle(Color.pabloBrownDeep)

            statusBadge
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            if isConnecting {
                ProgressView()
                    .controlSize(.small)
                Text("Connecting...")
            } else {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(pabloStateLabel)
            }
        }
        .font(.pabloBody(12))
        .foregroundStyle(Color.pabloBrownSoft)
    }

    // MARK: - Controls

    private var controlsSection: some View {
        HStack(spacing: 24) {
            pauseResumeButton
            endSessionButton
        }
        .padding(.bottom, 8)
    }

    private var pauseResumeButton: some View {
        Button {
            isPaused.toggle()
            if isPaused { onPause() } else { onResume() }
        } label: {
            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: 20))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.pabloBrownDeep)
        .disabled(isConnecting)
        .accessibilityLabel(isPaused ? "Resume session" : "Pause session")
    }

    private var endSessionButton: some View {
        Button { onEnd() } label: {
            Text("End Session")
                .font(.pabloBody(14).weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.pabloError)
                )
        }
        .buttonStyle(.plain)
        .disabled(isConnecting)
        .accessibilityLabel("End practice session")
    }

    // MARK: - Helpers

    private var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var pabloStateLabel: String {
        switch pabloState {
        case .listening: "Listening"
        case .processing: "Thinking..."
        case .speaking: "Speaking"
        }
    }

    private var statusColor: Color {
        switch pabloState {
        case .listening: Color.pabloSage
        case .processing: Color.pabloHoney
        case .speaking: Color.pabloHoney
        }
    }
}

// MARK: - Waveform Bar

/// A simple horizontal bar that reflects the audio level.
struct WaveformBar: View {
    let level: Float
    let color: Color
    let label: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.pabloBody(11))
                .foregroundStyle(Color.pabloBrownSoft)
                .frame(width: 40, alignment: .trailing)

            GeometryReader { geometry in
                let width = max(4, CGFloat(level) * geometry.size.width)
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.opacity(0.6))
                    .frame(width: width, height: 6)
                    .frame(maxHeight: .infinity, alignment: .center)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: level)
            }
        }
        .frame(height: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) audio level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}
