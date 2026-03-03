#if DEBUG
import SwiftUI

/// Smoke-test view for exercising RecordingService end-to-end.
/// Accessible from SettingsView in Debug builds only — not visible in Release.
struct DebugRecordingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var vm = RecordingViewModel()

    var body: some View {
        VStack(spacing: 20) {
            header
            stateSection
            controls
            if let path = vm.recordings.first?.fileURL {
                fileSection(url: path)
            }
        }
        .padding(24)
        .frame(minWidth: 380)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .task { await vm.loadAudioSources() }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("Debug Recording")
                .font(.title2.bold())
            Text("Smoke test — exercises RecordingService end-to-end")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var stateSection: some View {
        GroupBox("State") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Status") {
                    stateBadge
                }
                LabeledContent("Duration", value: formattedDuration)
                LabeledContent("Mic level", value: String(format: "%.2f", vm.micLevel))
                LabeledContent("System level", value: String(format: "%.2f", vm.systemLevel))
                LabeledContent("Recordings captured", value: "\(vm.recordings.count)")
            }
            .font(.system(.caption, design: .monospaced))
        }
    }

    private var stateBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
            Text(stateLabel)
                .foregroundStyle(stateColor)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            switch vm.recordingState {
            case .idle: idleControls
            case .recording: activeControls(primaryLabel: "Pause", primaryAction: vm.pauseRecording)
            case .paused: activeControls(primaryLabel: "Resume", primaryAction: vm.resumeRecording)
            }

            if vm.recordingState == .idle {
                Toggle("Encryption", isOn: $vm.encryptionEnabled)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
        }
    }

    private var idleControls: some View {
        Button("Start Recording") {
            Task { await vm.startRecording() }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private func activeControls(primaryLabel: String, primaryAction: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Button(primaryLabel, action: primaryAction)
                .buttonStyle(.bordered)
            Button("Stop") {
                Task { await vm.stopRecording() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
    }

    private func fileSection(url: URL) -> some View {
        GroupBox("Last Recording") {
            VStack(alignment: .leading, spacing: 8) {
                Text(url.lastPathComponent)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Button("Open in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Helpers

    private var stateLabel: String {
        switch vm.recordingState {
        case .idle: "Idle"
        case .recording: "Recording"
        case .paused: "Paused"
        }
    }

    private var stateColor: Color {
        switch vm.recordingState {
        case .idle: .secondary
        case .recording: .red
        case .paused: .orange
        }
    }

    private var formattedDuration: String {
        let minutes = Int(vm.duration) / 60
        let seconds = Int(vm.duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview {
    DebugRecordingView()
}
#endif
