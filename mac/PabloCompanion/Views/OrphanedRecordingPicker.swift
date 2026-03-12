import SwiftUI

/// Shows a list of unlinked recordings so the user can associate one with a session.
struct OrphanedRecordingPicker: View {
    let recordings: [LocalRecording]
    var onLink: ((LocalRecording) -> Void)?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            expandButton
            if expanded {
                VStack(spacing: 6) {
                    ForEach(recordings) { recording in
                        OrphanedRecordingRow(recording: recording) {
                            onLink?(recording)
                        }
                    }
                }
            }
        }
    }

    private var expandButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "link.badge.plus")
                Text("Link existing recording (\(recordings.count) available)")
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
            }
            .font(.pabloBody(12))
            .foregroundStyle(Color.pabloHoney)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Link an existing recording to this session")
    }
}

// MARK: - Row

private struct OrphanedRecordingRow: View {
    let recording: LocalRecording
    var onLink: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .foregroundStyle(Color.pabloHoney)
                .font(.pabloBody(12))
                .accessibilityHidden(true)
            metadata
            Spacer()
            linkButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.pabloHoney.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.pabloBody(12))
                .foregroundStyle(Color.pabloBrownDeep)
            HStack(spacing: 8) {
                Text(recording.formattedDuration)
                Text(fileSizeString)
                if recording.micPCMFileURL != nil { Text("mic") }
                if recording.systemPCMFileURL != nil { Text("system") }
            }
            .font(.pabloBody(10))
            .foregroundStyle(Color.pabloBrownSoft)
        }
    }

    private var linkButton: some View {
        Button("Link", action: onLink)
            .font(.pabloBody(11))
            .buttonStyle(.borderedProminent)
            .tint(Color.pabloHoney)
            .controlSize(.mini)
            .accessibilityLabel("Link recording from \(recording.createdAt.formatted())")
    }

    private var fileSizeString: String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: recording.fileURL.path),
              let size = attrs[.size] as? UInt64
        else { return "" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }
}

#Preview {
    OrphanedRecordingPicker(recordings: [])
        .padding()
}
