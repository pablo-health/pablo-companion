import SwiftUI

/// Displays a list of past recordings with metadata and upload controls.
struct RecordingListView: View {
    let recordings: [LocalRecording]
    let uploadProgress: [UUID: Double]
    let uploadingIDs: Set<UUID>
    let playingRecordingID: UUID?
    let onUpload: (LocalRecording) -> Void
    let onPlay: (LocalRecording) -> Void
    let onStopPlayback: () -> Void

    var body: some View {
        Group {
            if recordings.isEmpty {
                emptyState
            } else {
                recordingList
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image("PabloBear")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
            Text("No recordings yet")
                .font(.pabloDisplay(17))
                .foregroundStyle(Color.pabloBrownDeep)
            Text("Start recording to see your sessions here.")
                .font(.pabloBody(13))
                .foregroundStyle(Color.pabloBrownSoft)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var recordingList: some View {
        List(recordings) { recording in
            RecordingRow(
                recording: recording,
                uploadProgress: uploadProgress[recording.id],
                isUploading: uploadingIDs.contains(recording.id),
                isPlaying: playingRecordingID == recording.id,
                onUpload: { onUpload(recording) },
                onPlay: { onPlay(recording) },
                onStopPlayback: onStopPlayback
            )
            .pabloListRowStyle()
        }
        .pabloListStyle()
    }
}

struct RecordingRow: View {
    let recording: LocalRecording
    let uploadProgress: Double?
    let isUploading: Bool
    let isPlaying: Bool
    let onUpload: () -> Void
    let onPlay: () -> Void
    let onStopPlayback: () -> Void

    var body: some View {
        HStack {
            Button(action: isPlaying ? onStopPlayback : onPlay) {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help(isPlaying ? "Stop" : "Play")

            VStack(alignment: .leading, spacing: 4) {
                Text(recording.fileName)
                    .font(.pabloBody(14)).fontWeight(.semibold)
                    .lineLimit(1)

                HStack(spacing: 12) {
                    Label(recording.formattedDuration, systemImage: "clock")
                    Label(recording.formattedDate, systemImage: "calendar")
                    if recording.isEncrypted {
                        Label("Encrypted", systemImage: "lock.fill")
                            .foregroundStyle(Color.pabloSage)
                    }
                }
                .font(.pabloBody(11))
                .foregroundStyle(.secondary)
            }

            Spacer()

            uploadStatus
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var uploadStatus: some View {
        if recording.isUploaded {
            Label("Uploaded", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.pabloSage)
                .font(.caption)
        } else if isUploading {
            VStack(spacing: 2) {
                ProgressView(value: uploadProgress ?? 0)
                    .frame(width: 80)
                Text("\(Int((uploadProgress ?? 0) * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            Button("Upload", action: onUpload)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

#Preview("Empty") {
    RecordingListView(
        recordings: [],
        uploadProgress: [:],
        uploadingIDs: [],
        playingRecordingID: nil,
        onUpload: { _ in },
        onPlay: { _ in },
        onStopPlayback: {}
    )
    .frame(width: 500, height: 400)
}

private func makePreviewRecordings() -> [LocalRecording] {
    [
        LocalRecording(
            id: UUID(),
            fileURL: URL(fileURLWithPath: "/recordings/session-2026-02-25.m4a"),
            duration: 3661,
            createdAt: Date(),
            isEncrypted: true,
            checksum: "abc123",
            channelLayout: .separatedStereo,
            isUploaded: false
        ),
        LocalRecording(
            id: UUID(),
            fileURL: URL(fileURLWithPath: "/recordings/session-2026-02-20.m4a"),
            duration: 2820,
            createdAt: Date().addingTimeInterval(-432_000),
            isEncrypted: true,
            checksum: "def456",
            channelLayout: .separatedStereo,
            isUploaded: true
        ),
    ]
}

#Preview("With recordings") {
    RecordingListView(
        recordings: makePreviewRecordings(),
        uploadProgress: [:],
        uploadingIDs: [],
        playingRecordingID: nil,
        onUpload: { _ in },
        onPlay: { _ in },
        onStopPlayback: {}
    )
    .frame(width: 500, height: 400)
}
