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
        .accessibilityLabel("Start recording")
    }

    private var recordingButtons: some View {
        Group {
            Button(action: onPause) {
                Label("Pause", systemImage: "pause.circle")
                    .font(.title2)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityLabel("Pause recording")

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
            .accessibilityLabel("Resume recording")

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
        .accessibilityLabel("Stop recording")
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
