import AppKit
import SwiftUI

/// Detail view for a single session — shows session info, recording status,
/// transcription controls, and inline transcript text.
struct SessionDetailView: View {
    let session: Session
    var patient: Patient?
    var recording: LocalRecording?
    var transcriptionState: TranscriptionState?
    var isPlaying = false
    var onTranscribe: (() -> Void)?
    var onPlay: (() -> Void)?
    var onStopPlayback: (() -> Void)?
    var onEndSession: (() -> Void)?
    var orphanedRecordings: [LocalRecording] = []
    var onLinkRecording: ((LocalRecording) -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    sessionInfoSection
                    if recording != nil {
                        recordingSection
                    } else {
                        noRecordingSection
                    }
                    transcriptionSection
                }
                .padding(20)
            }
        }
        .frame(minWidth: 520, minHeight: 480)
        .background(Color.pabloCream)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(patientName)
                    .font(.pabloDisplay(20))
                    .foregroundStyle(Color.pabloBrownDeep)
                Text(SessionFormatting.dateString(session.scheduledAt))
                    .font(.pabloBody(13))
                    .foregroundStyle(Color.pabloBrownSoft)
            }
            Spacer()
            SessionStatusBadge(status: session.status)
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.pabloBrownSoft)
                    .font(.title2)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Close session detail")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Session Info

    private var sessionInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailSectionHeader("Session Info")
            sessionInfoFields
            sessionNotes
            endSessionButton
        }
        .cardBackground()
        .padding(.horizontal, -4)
    }

    private var sessionInfoFields: some View {
        HStack(spacing: 24) {
            DetailInfoItem(label: "Time", value: SessionFormatting.timeString(session.scheduledAt))
            DetailInfoItem(label: "Duration", value: "\(session.durationMinutes ?? 0) min")
            if let platform = session.videoPlatform, platform != .none {
                DetailInfoItem(label: "Platform", value: SessionFormatting.platformName(platform))
            }
            if let sessionType = session.sessionType {
                DetailInfoItem(label: "Type", value: SessionFormatting.sessionTypeName(sessionType))
            }
        }
    }

    @ViewBuilder
    private var sessionNotes: some View {
        if let notes = session.notes, !notes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Notes")
                    .font(.pabloBody(11))
                    .foregroundStyle(Color.pabloBrownSoft)
                Text(notes)
                    .font(.pabloBody(13))
                    .foregroundStyle(Color.pabloBrownDeep)
            }
        }
    }

    @ViewBuilder
    private var endSessionButton: some View {
        if session.status == .inProgress, let onEndSession {
            Button(action: onEndSession) {
                Text("End Session")
                    .font(.pabloBody(13))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.pabloError)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End this stale in-progress session")
        }
    }

    // MARK: - Recording Section

    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailSectionHeader("Recording")
            if let recording {
                RecordingInfoContent(
                    recording: recording,
                    isPlaying: isPlaying,
                    transcriptionState: transcriptionState,
                    onTranscribe: onTranscribe,
                    onPlay: onPlay,
                    onStopPlayback: onStopPlayback
                )
            }
        }
        .cardBackground()
        .padding(.horizontal, -4)
    }

    private var noRecordingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            DetailSectionHeader("Recording")
            HStack(spacing: 8) {
                Image(systemName: "waveform.slash")
                    .foregroundStyle(Color.pabloBrownSoft)
                    .accessibilityHidden(true)
                Text("No local recording found for this session.")
                    .font(.pabloBody(13))
                    .foregroundStyle(Color.pabloBrownSoft)
            }
            if !orphanedRecordings.isEmpty {
                OrphanedRecordingPicker(
                    recordings: orphanedRecordings,
                    onLink: { onLinkRecording?($0) }
                )
            }
        }
        .cardBackground()
        .padding(.horizontal, -4)
    }

    // MARK: - Transcription Section

    private var transcriptionSection: some View {
        TranscriptionSectionContent(
            state: transcriptionState,
            onTranscribe: onTranscribe
        )
    }

    // MARK: - Helpers

    private var patientName: String {
        if let patient = session.patient {
            return "\(patient.firstName) \(patient.lastName)"
        }
        if let patient {
            return "\(patient.firstName) \(patient.lastName)"
        }
        return "Session"
    }
}

// MARK: - Reusable Detail Subviews

struct DetailSectionHeader: View {
    let title: String
    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.pabloDisplay(15))
            .foregroundStyle(Color.pabloBrownDeep)
    }
}

struct DetailInfoItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.pabloBody(11))
                .foregroundStyle(Color.pabloBrownSoft)
            Text(value)
                .font(.pabloBody(14))
                .foregroundStyle(Color.pabloBrownDeep)
        }
    }
}

struct SessionStatusBadge: View {
    let status: SessionStatus

    var body: some View {
        Text(SessionFormatting.statusLabel(status))
            .font(.pabloBody(12))
            .foregroundStyle(SessionFormatting.statusForeground(status))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(SessionFormatting.statusBackground(status))
            .clipShape(Capsule())
    }
}

// MARK: - Recording Info Content

private struct RecordingInfoContent: View {
    let recording: LocalRecording
    var isPlaying = false
    var transcriptionState: TranscriptionState?
    var onTranscribe: (() -> Void)?
    var onPlay: (() -> Void)?
    var onStopPlayback: (() -> Void)?

    var body: some View {
        HStack(spacing: 24) {
            DetailInfoItem(label: "Duration", value: recording.formattedDuration)
            DetailInfoItem(label: "Recorded", value: recording.formattedDate)
            DetailInfoItem(label: "Size", value: fileSizeString(recording.fileURL))
        }
        audioChannelLabels
        HStack(spacing: 8) {
            playButton
            transcribeButton
        }
    }

    private var audioChannelLabels: some View {
        HStack(spacing: 4) {
            if recording.micPCMFileURL != nil {
                Label("Mic audio", systemImage: "mic.fill")
                    .font(.pabloBody(11))
                    .foregroundStyle(Color.pabloSage)
            }
            if recording.systemPCMFileURL != nil {
                Label("System audio", systemImage: "speaker.wave.2.fill")
                    .font(.pabloBody(11))
                    .foregroundStyle(Color.pabloSage)
            }
            if recording.isEncrypted {
                Label("Encrypted", systemImage: "lock.fill")
                    .font(.pabloBody(11))
                    .foregroundStyle(Color.pabloSage)
            }
        }
    }

    @ViewBuilder
    private var playButton: some View {
        if isPlaying {
            Button(action: { onStopPlayback?() }) {
                Label("Stop", systemImage: "stop.fill").font(.pabloBody(13))
            }
            .buttonStyle(.bordered).controlSize(.small)
            .accessibilityLabel("Stop playback")
        } else if onPlay != nil {
            Button(action: { onPlay?() }) {
                Label("Play", systemImage: "play.fill").font(.pabloBody(13))
            }
            .buttonStyle(.bordered).controlSize(.small)
            .accessibilityLabel("Play recording")
        }
    }

    @ViewBuilder
    private var transcribeButton: some View {
        if transcriptionState == nil, recording.micPCMFileURL != nil, let onTranscribe {
            Button(action: onTranscribe) {
                Label("Transcribe", systemImage: "text.bubble").font(.pabloBody(13))
            }
            .buttonStyle(.borderedProminent).tint(Color.pabloHoney).controlSize(.small)
            .accessibilityLabel("Transcribe this session")
        }
    }

    private func fileSizeString(_ url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64
        else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }
}

// MARK: - Transcription Section Content

private struct TranscriptionSectionContent: View {
    let state: TranscriptionState?
    var onTranscribe: (() -> Void)?

    var body: some View {
        switch state {
        case let .done(transcript), let .pendingUpload(transcript):
            transcriptCard(transcript, isPending: state?.isPendingUpload == true)
        case .running:
            progressCard("Transcribing…")
        case .awaitingModel:
            progressCard("Awaiting model download…")
        case let .failed(message):
            failedCard(message)
        case nil:
            EmptyView()
        }
    }

    private func transcriptCard(_ transcript: String, isPending: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                DetailSectionHeader("Transcript")
                Spacer()
                if isPending {
                    Text("Pending upload")
                        .font(.pabloBody(11))
                        .foregroundStyle(Color.pabloHoney)
                }
                CopyButton(text: transcript)
            }
            Text(transcript)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Color.pabloBrownDeep)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .cardBackground()
        .padding(.horizontal, -4)
    }

    private func progressCard(_ label: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailSectionHeader("Transcript")
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(label)
                    .font(.pabloBody(13))
                    .foregroundStyle(Color.pabloBrownSoft)
            }
        }
        .cardBackground()
        .padding(.horizontal, -4)
    }

    private func failedCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailSectionHeader("Transcript")
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.pabloError)
                    .accessibilityHidden(true)
                Text("Transcription failed: \(message)")
                    .font(.pabloBody(13))
                    .foregroundStyle(Color.pabloError)
            }
            if let onTranscribe {
                Button("Retry Transcription", action: onTranscribe)
                    .buttonStyle(.bordered).controlSize(.small)
                    .tint(Color.pabloError)
                    .accessibilityLabel("Retry transcription")
            }
        }
        .cardBackground()
        .padding(.horizontal, -4)
    }
}

// MARK: - Copy Button

private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied!" : "Copy All") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        }
        .font(.pabloBody(11))
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .tint(copied ? Color.pabloSage : Color.pabloHoney)
        .accessibilityLabel(copied ? "Transcript copied" : "Copy entire transcript")
    }
}

#Preview {
    SessionDetailView(
        session: PreviewData.inProgress,
        transcriptionState: .done(
            transcript: "Google Meet Transcript\n\n[00:00:08]\nTherapist: Hello."
        )
    )
}
