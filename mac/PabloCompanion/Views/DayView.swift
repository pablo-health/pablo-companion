import SwiftUI

/// Today's session list — the hero view of Pablo Companion.
///
/// Shows scheduled sessions for the day, auto-refreshes on appear,
/// and provides the entry point to start a session.
struct DayView: View {
    var sessionVM: SessionViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color.pabloCream)
        .task { await sessionVM.loadTodaySessions() }
        .refreshable { await sessionVM.loadTodaySessions() }
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
                ProgressView()
                    .controlSize(.small)
            }
            sessionCountBadge
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
        List {
            ForEach(sessionVM.todaySessions, id: \.id) { session in
                SessionRowView(session: session)
                    .pabloListRowStyle()
                    .padding(.vertical, 2)
            }
        }
        .pabloListStyle()
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()

            // Warm honey circle with calendar icon
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

// MARK: - Preview helpers

private func previewVM(sessions: [Session] = []) -> SessionViewModel {
    let vm = SessionViewModel()
    vm.todaySessions = sessions
    return vm
}

#Preview("With sessions") {
    DayView(sessionVM: previewVM(sessions: [
        PreviewData.scheduled,
        PreviewData.inProgress,
    ]))
}

#Preview("Empty") {
    DayView(sessionVM: previewVM())
}
