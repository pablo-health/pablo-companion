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
    var onStartSession: ((Session) -> Void)?
    var onQuickStart: ((Patient) -> Void)?
    var onStopRecording: (() -> Void)?

    @State private var lastRefreshDate = Date()
    @State private var showingQuickStart = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if recordingState != .idle {
                recordingBanner
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
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.pabloSage.opacity(0.1))
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
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
                    SessionRowView(session: session) {
                        onStartSession?(session)
                    }
                    .pabloListRowStyle()
                    .padding(.vertical, 2)
                }
            }
            .pabloListStyle()

            lastUpdatedLabel
        }
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

    // MARK: - Polling

    private func pollSessions() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { break }
            guard recordingState == .idle else { continue }
            await sessionVM.loadTodaySessions()
            lastRefreshDate = Date()
        }
    }

    // MARK: - Helpers

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: Date())
    }

    private var greeting: String {
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
