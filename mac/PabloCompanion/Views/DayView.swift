import SwiftUI

/// Today's session list — the hero view of Pablo Companion.
///
/// Shows scheduled sessions, provides Start Session + Quick Start flows,
/// and polls the backend every 30 seconds to keep statuses fresh.
struct DayView: View {
    var sessionVM: SessionViewModel
    var patients: [Patient]
    var isLoadingPatients: Bool
    @Binding var patientSearchText: String
    var recordingState: RecordingUIState = .idle
    var recordingDuration: TimeInterval = 0
    var pendingUploadCount = 0
    var awaitingModelCount = 0
    var transcriptionStateForSession: ((String) -> TranscriptionState?)?
    var hasRecordingForSession: ((String) -> Bool)?
    var playingSessionId: String?
    var onStartSession: ((Session) -> Void)?
    var onQuickStart: ((Patient) -> Void)?
    var onStopRecording: (() -> Void)?
    var recordingStalled = false
    var recordingError: String?
    var onRetryCapture: (() -> Void)?
    var onDismissError: (() -> Void)?
    var onRetryUploads: (() -> Void)?
    var onSwitchToSettings: (() -> Void)?
    var onViewTranscript: ((Session) -> Void)?
    var onTranscribeSession: ((Session) -> Void)?
    var onPlaySession: ((Session) -> Void)?
    var onStopPlayback: (() -> Void)?
    var onEndSession: ((Session) -> Void)?
    var activeSessionId: String?
    var onSessionTapped: ((Session) -> Void)?

    @State private var lastRefreshDate = Date()
    @State private var showingQuickStart = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if recordingState != .idle {
                recordingBanner
            }
            if recordingState != .idle, recordingStalled {
                stallWarningBanner
            }
            if let error = recordingError {
                persistentErrorBanner(error)
            }
            if pendingUploadCount > 0 {
                transcriptionPendingBanner
            }
            if awaitingModelCount > 0 {
                awaitingModelBanner
            }
            Divider()
            content
        }
        .background(Color.pabloCream)
        .task { await pollSessions() }
        .sheet(isPresented: $showingQuickStart) {
            QuickStartSheet(
                patients: patients,
                isLoading: isLoadingPatients,
                searchText: $patientSearchText,
                onSelect: { patient in onQuickStart?(patient) }
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting)
                    .font(.pabloDisplay(24))
                    .foregroundStyle(Color.pabloBrownDeep)
                Text(formattedDate)
                    .font(.pabloBody(14))
                    .foregroundStyle(Color.pabloBrownSoft)
            }
            Spacer()
            if sessionVM.isLoading {
                ProgressView().controlSize(.small)
            }
            sessionCountBadge
            quickStartButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var sessionCountBadge: some View {
        Group {
            if !sessionVM.todaySessions.isEmpty {
                Text("\(sessionVM.todaySessions.count)")
                    .font(.pabloBody(12))
                    .foregroundStyle(Color.pabloBrownDeep)
                    .frame(width: 24, height: 24)
                    .background(Color.pabloHoney.opacity(0.2))
                    .clipShape(Circle())
            }
        }
    }

    private var quickStartButton: some View {
        Button { showingQuickStart = true } label: {
            Label("Quick Start", systemImage: "plus.circle.fill")
                .font(.pabloBody(13))
                .foregroundStyle(Color.pabloBrownDeep)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.pabloHoney)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Quick start new session")
    }

    // MARK: - Recording Banner

    private var recordingBanner: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.pabloSage)
                .frame(width: 10, height: 10)
                .overlay(
                    Circle()
                        .fill(Color.pabloSage.opacity(0.4))
                        .frame(width: 18, height: 18)
                )

            Text(recordingState == .paused ? "Paused" : "Recording")
                .font(.pabloBody(14))
                .fontWeight(.medium)
                .foregroundStyle(Color.pabloBrownDeep)

            Text(formattedDuration(recordingDuration))
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(Color.pabloBrownSoft)

            Spacer()

            Button {
                onStopRecording?()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.pabloBody(13))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.pabloError)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop recording session")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.pabloSage.opacity(0.1))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if sessionVM.isLoading, sessionVM.todaySessions.isEmpty {
            loadingState
        } else if sessionVM.todaySessions.isEmpty {
            emptyState
        } else {
            sessionList
        }
    }

    private var sessionList: some View {
        VStack(spacing: 0) {
            List {
                ForEach(sessionVM.todaySessions, id: \.id) { session in
                    sessionRow(session)
                        .pabloListRowStyle()
                        .padding(.vertical, 2)
                }
            }
            .pabloListStyle()

            lastUpdatedLabel
        }
    }

    private func sessionRow(_ session: Session) -> some View {
        let state = transcriptionStateForSession?(session.id)
        let hasRecording = hasRecordingForSession?(session.id) ?? false
        let isPlaying = playingSessionId == session.id
        let isStaleInProgress = session.status == .inProgress && session.id != activeSessionId

        return SessionRowView(
            session: session,
            patientLookup: { id in patients.first { $0.id == id } },
            transcriptionState: state,
            hasRecording: hasRecording,
            isPlaying: isPlaying,
            onStart: { onStartSession?(session) },
            onViewTranscript: state?.transcript != nil
                ? { onViewTranscript?(session) } : nil,
            onTranscribe: hasRecording
                ? { onTranscribeSession?(session) } : nil,
            onPlay: hasRecording
                ? { onPlaySession?(session) } : nil,
            onStopPlayback: isPlaying
                ? { onStopPlayback?() } : nil,
            onEndSession: isStaleInProgress
                ? { onEndSession?(session) } : nil
        )
        .contentShape(Rectangle())
        .onTapGesture { onSessionTapped?(session) }
    }

    private var lastUpdatedLabel: some View {
        Text("Updated \(lastRefreshDate, format: .relative(presentation: .named))")
            .font(.pabloBody(11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.pabloHoney.opacity(0.12))
                    .frame(width: 80, height: 80)
                Image(systemName: "calendar")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(Color.pabloHoney)
                    .accessibilityHidden(true)
            }
            Text("No sessions today")
                .font(.pabloDisplay(20))
                .foregroundStyle(Color.pabloBrownDeep)
            Text("Your schedule is clear.\nSessions scheduled in Pablo will appear here.")
                .font(.pabloBody(14))
                .foregroundStyle(Color.pabloBrownSoft)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }

    // MARK: - Loading state

    private var loadingState: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .controlSize(.large)
                .tint(Color.pabloHoney)
            Text("Loading sessions...")
                .font(.pabloBody(14))
                .foregroundStyle(Color.pabloBrownSoft)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

}

// MARK: - DayView Banners & Helpers

extension DayView {
    var stallWarningBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.pabloHoney)
                .accessibilityHidden(true)
            Text("Audio capture may have stalled — no new data in the last 60 seconds")
                .font(.pabloBody(13))
                .foregroundStyle(Color.pabloBrownDeep)
            Spacer()
            Button("Retry Capture") { onRetryCapture?() }
                .font(.pabloBody(12))
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Retry audio capture")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.pabloHoney.opacity(0.2))
    }

    func persistentErrorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Color.pabloError)
                .accessibilityHidden(true)
            Text(message)
                .font(.pabloBody(13))
                .foregroundStyle(Color.pabloBrownDeep)
                .lineLimit(2)
            Spacer()
            Button {
                onDismissError?()
            } label: {
                Image(systemName: "xmark")
                    .font(.pabloBody(12))
                    .foregroundStyle(Color.pabloBrownSoft)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.pabloError.opacity(0.12))
    }

    func formattedDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var transcriptionPendingBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(Color.pabloHoney)
                .accessibilityHidden(true)
            Text("\(pendingUploadCount) transcript\(pendingUploadCount == 1 ? "" : "s") pending upload")
                .font(.pabloBody(13))
                .foregroundStyle(Color.pabloBrownDeep)
            Spacer()
            Button("Retry Now") { onRetryUploads?() }
                .font(.pabloBody(12))
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Retry uploading pending transcripts")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.pabloHoney.opacity(0.12))
    }

    var awaitingModelBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(Color.pabloHoney)
                .accessibilityHidden(true)
            Text("\(awaitingModelCount) session\(awaitingModelCount == 1 ? "" : "s") awaiting model download")
                .font(.pabloBody(13))
                .foregroundStyle(Color.pabloBrownDeep)
            Spacer()
            Button("Go to Settings") { onSwitchToSettings?() }
                .font(.pabloBody(12))
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Go to Settings to download transcription model")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.pabloHoney.opacity(0.12))
    }

    func pollSessions() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { break }
            guard recordingState == .idle else { continue }
            await sessionVM.loadTodaySessions()
            lastRefreshDate = Date()
        }
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: Date())
    }

    var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 0 ..< 12: return "Good morning"
        case 12 ..< 17: return "Good afternoon"
        default: return "Good evening"
        }
    }
}

// MARK: - Preview

#Preview("With sessions") {
    DayView(
        sessionVM: {
            let vm = SessionViewModel()
            vm.todaySessions = [PreviewData.scheduled, PreviewData.inProgress]
            return vm
        }(),
        patients: [],
        isLoadingPatients: false,
        patientSearchText: .constant("")
    )
}

#Preview("Empty") {
    DayView(
        sessionVM: SessionViewModel(),
        patients: [],
        isLoadingPatients: false,
        patientSearchText: .constant("")
    )
}
