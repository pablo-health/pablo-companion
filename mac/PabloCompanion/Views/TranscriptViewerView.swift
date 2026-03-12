import AppKit
import SwiftUI

/// Data passed to the transcript viewer sheet.
struct TranscriptViewerItem: Identifiable {
    let id: UUID
    let text: String
    let recordingDate: Date
}

/// In-app transcript viewer — displays the Google Meet formatted transcript
/// with a one-tap copy button. No plain text is written to disk; display is
/// in memory only, keeping PHI off the filesystem.
struct TranscriptViewerView: View {
    let transcript: String
    let recordingDate: Date

    @State private var copied = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcriptScroll
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(Color.pabloCream)
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Session Transcript")
                    .font(.pabloDisplay(17))
                    .foregroundStyle(Color.pabloBrownDeep)
                Text(recordingDate.formatted(date: .long, time: .shortened))
                    .font(.pabloBody(12))
                    .foregroundStyle(Color.pabloBrownSoft)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.pabloBrownSoft)
                    .font(.title2)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Close transcript viewer")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var transcriptScroll: some View {
        ScrollView {
            Text(transcript)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Color.pabloBrownDeep)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text("Select text to copy a portion, or use Copy All below.")
                .font(.pabloBody(11))
                .foregroundStyle(Color.pabloBrownSoft)

            Spacer()

            Button(copied ? "Copied!" : "Copy All") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(transcript, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(copied ? Color.pabloSage : Color.pabloHoney)
            .controlSize(.regular)
            .accessibilityLabel(copied ? "Transcript copied to clipboard" : "Copy entire transcript to clipboard")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

#Preview {
    TranscriptViewerView(
        transcript: """
        Google Meet Transcript
        Session Date: March 5, 2026
        Duration: 52:14

        [00:00:08]
        Dr. Lee: Good afternoon. How has the week been since we last met?

        [00:00:13]
        Alex: It's been rough. I couldn't sleep much this week.

        [Session ends 00:52:14]

        ---
        Total Duration: 52:14
        Speakers: 2
        Dr. Lee (Therapist)
        Alex (Client)
        """,
        recordingDate: Date()
    )
}
