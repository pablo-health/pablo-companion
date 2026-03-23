// #if DEBUG
import AppKit
import SwiftUI

/// Smoke-test view for exercising RecordingService end-to-end.
/// Accessible from SettingsView in Debug builds only — not visible in Release.
struct DebugRecordingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var vm = RecordingViewModel()
    @State private var transcriptionVM = TranscriptionViewModel()
    @State private var autoTranscribe = false
    @State private var viewingTranscript: String?

    var body: some View {
        VStack(spacing: 20) {
            header
            stateSection
            controls
            if let recording = vm.recordings.first {
                fileSection(recording: recording)
            }
        }
        .padding(24)
        .frame(minWidth: 380)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .task {
            await vm.loadAudioSources()
            vm.onRecordingCompleted = { [transcriptionVM] recording in
                guard autoTranscribe else { return }
                transcriptionVM.transcribeIfNeeded(recording)
            }
        }
        .sheet(item: Binding(
            get: {
                viewingTranscript.map {
                    TranscriptViewerItem(id: UUID(), text: $0, recordingDate: Date())
                }
            },
            set: { newValue in
                if newValue == nil { viewingTranscript = nil }
            }
        )) { item in
            TranscriptViewerView(transcript: item.text, recordingDate: item.recordingDate)
        }
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
                VStack(spacing: 8) {
                    Toggle("Encryption", isOn: $vm.encryptionEnabled)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    Toggle("Transcribe after recording", isOn: $autoTranscribe)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
            }
        }
    }

    private var idleControls: some View {
        Button("Start Recording") {
            Task { await vm.startRecording() }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityLabel("Start debug recording")
    }

    private func activeControls(primaryLabel: String, primaryAction: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Button(primaryLabel, action: primaryAction)
                .buttonStyle(.bordered)
                .accessibilityLabel("\(primaryLabel) recording")
            Button("Stop") {
                Task { await vm.stopRecording() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .accessibilityLabel("Stop debug recording")
        }
    }

    private func fileSection(recording: LocalRecording) -> some View {
        GroupBox("Last Recording") {
            VStack(alignment: .leading, spacing: 8) {
                Text(recording.fileURL.lastPathComponent)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Button("Open in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([recording.fileURL])
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Open recording file in Finder")

                transcriptionStatus(for: recording)
            }
        }
    }

    @ViewBuilder
    // swiftlint:disable:next function_body_length
    private func transcriptionStatus(for recording: LocalRecording) -> some View {
        let state = transcriptionVM.states[recording.id]
        switch state {
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Transcribing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .awaitingModel:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Awaiting model download…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case let .done(transcript), let .pendingUpload(transcript):
            HStack(spacing: 8) {
                Button("View Transcript") {
                    viewingTranscript = transcript
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("View transcription result")

                Button("Copy Transcript") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(transcript, forType: .string)
                    // Auto-clear pasteboard after 60s
                    let snapshot = transcript
                    Task {
                        try? await Task.sleep(for: .seconds(60))
                        if NSPasteboard.general.string(forType: .string) == snapshot {
                            NSPasteboard.general.clearContents()
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Copy transcript to clipboard")
            }
        case let .failed(message):
            VStack(alignment: .leading, spacing: 4) {
                Text("Transcription failed: \(message)")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Retry") {
                    Task { await transcriptionVM.transcribe(recording) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Retry transcription")
            }
        case nil:
            if recording.micPCMFileURL != nil {
                Button("Transcribe") {
                    Task { await transcriptionVM.transcribe(recording) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Transcribe this recording")
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

// #endif
