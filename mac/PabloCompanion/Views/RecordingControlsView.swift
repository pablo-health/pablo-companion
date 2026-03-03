import SwiftUI

/// Recording controls with record/pause/stop buttons and audio level meters.
struct RecordingControlsView: View {
    let state: RecordingUIState
    let duration: TimeInterval
    let micLevel: Float
    let systemLevel: Float
    let systemAudioActive: Bool

    let onStart: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(formattedDuration)
                .font(.system(size: 48, weight: .light, design: .monospaced))
                .foregroundStyle(state == .recording ? .primary : .secondary)

            Text(stateLabel)
                .font(.pabloBody(11))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            HStack(spacing: 24) {
                LevelMeter(label: "Mic", level: micLevel)
                LevelMeter(label: "System", level: systemLevel)
            }
            .frame(height: 100)
            .padding(.vertical, 8)

            systemAudioStatus
            controlButtons
        }
        .padding()
        .background(Color.pabloCream)
    }

    @ViewBuilder
    private var systemAudioStatus: some View {
        if state == .recording || state == .paused {
            StatusIndicator(
                isActive: systemAudioActive,
                activeLabel: "System Audio: Active",
                inactiveLabel: "System Audio: Unavailable"
            )
        }
    }

    private var controlButtons: some View {
        HStack(spacing: 20) {
            switch state {
            case .idle:
                idleButtons
            case .recording:
                recordingButtons
            case .paused:
                pausedButtons
            }
        }
    }

    private var idleButtons: some View {
        Button(action: onStart) {
            Label("Record", systemImage: "record.circle")
                .font(.title2)
        }
        .buttonStyle(.borderedProminent)
        .tint(.pabloHoney)
        .controlSize(.large)
    }

    private var recordingButtons: some View {
        Group {
            Button(action: onPause) {
                Label("Pause", systemImage: "pause.circle")
                    .font(.title2)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            stopButton
        }
    }

    private var pausedButtons: some View {
        Group {
            Button(action: onResume) {
                Label("Resume", systemImage: "play.circle")
                    .font(.title2)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            stopButton
        }
    }

    private var stopButton: some View {
        Button(action: onStop) {
            Label("Stop", systemImage: "stop.circle")
                .font(.title2)
        }
        .buttonStyle(.borderedProminent)
        .tint(.pabloBrownDeep)
        .controlSize(.large)
    }

    private var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var stateLabel: String {
        switch state {
        case .idle: "Ready"
        case .recording: "Recording"
        case .paused: "Paused"
        }
    }
}

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

#Preview("Idle") {
    RecordingControlsView(
        state: .idle,
        duration: 0,
        micLevel: 0,
        systemLevel: 0,
        systemAudioActive: false,
        onStart: {},
        onPause: {},
        onResume: {},
        onStop: {}
    )
    .frame(width: 400)
}

#Preview("Recording") {
    RecordingControlsView(
        state: .recording,
        duration: 125,
        micLevel: 0.6,
        systemLevel: 0.4,
        systemAudioActive: true,
        onStart: {},
        onPause: {},
        onResume: {},
        onStop: {}
    )
    .frame(width: 400)
}
