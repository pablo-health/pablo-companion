import SwiftUI

/// Browsable, paginated list of all sessions with status filtering.
struct SessionHistoryView: View {
    @Bindable var viewModel: SessionViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            filterBar
            Divider()
            sessionContent
        }
        .background(Color.pabloCream)
        .task { await viewModel.loadSessions() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sessions")
                .font(.pabloDisplay(24))
                .foregroundStyle(Color.pabloBrownDeep)

            Text(subtitleText)
                .font(.pabloBody(13))
                .foregroundStyle(Color.pabloBrownSoft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private var subtitleText: String {
        let total = viewModel.totalSessions
        if total == 0, viewModel.isLoadingSessions {
            return "Loading sessions..."
        }
        if total == 1 {
            return "1 session"
        }
        return "\(total) sessions"
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterCapsule(label: "All", value: nil)
                filterCapsule(label: "Scheduled", value: "scheduled")
                filterCapsule(label: "In Progress", value: "in_progress")
                filterCapsule(label: "Recorded", value: "recording_complete")
                filterCapsule(label: "Complete", value: "finalized")
                filterCapsule(label: "Cancelled", value: "cancelled")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }

    private func filterCapsule(label: String, value: String?) -> some View {
        let isSelected = viewModel.statusFilter == value
        return Button {
            viewModel.statusFilter = value
        } label: {
            Text(label)
                .font(.pabloBody(12))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    isSelected
                        ? filterColor(for: value)
                        : Color.clear
                )
                .foregroundStyle(
                    isSelected
                        ? Color.white
                        : Color.pabloBrownSoft
                )
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(
                            isSelected
                                ? Color.clear
                                : Color.pabloBrownSoft.opacity(0.3),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    @ViewBuilder
    private var sessionContent: some View {
        if viewModel.isLoadingSessions, viewModel.sessions.isEmpty {
            loadingState
        } else if let error = viewModel.errorMessage, viewModel.sessions.isEmpty {
            errorState(error)
        } else if viewModel.sessions.isEmpty {
            emptyState
        } else {
            sessionList
        }
    }

    private var loadingState: some View {
        VStack {
            Spacer()
            ProgressView("Loading sessions...")
                .font(.pabloBody(14))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(Color.pabloError)
            Text("Failed to Load Sessions")
                .font(.pabloDisplay(18))
                .foregroundStyle(Color.pabloBrownDeep)
            Text(message)
                .font(.pabloBody(12))
                .foregroundStyle(Color.pabloBrownSoft)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .padding(.horizontal, 40)
            Button("Retry") {
                Task { await viewModel.loadSessions() }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.pabloHoney)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Sessions",
            systemImage: "calendar.badge.exclamationmark",
            description: Text(emptyDescription)
        )
    }

    private var emptyDescription: String {
        if viewModel.statusFilter != nil {
            return "No sessions match the selected filter."
        }
        return "No sessions found. Sessions will appear here after they are created."
    }

    private var sessionList: some View {
        List {
            ForEach(viewModel.sessions, id: \.id) { session in
                SessionRowView(session: session)
                    .pabloListRowStyle()
            }
            if viewModel.hasMoreSessions {
                loadMoreButton
                    .pabloListRowStyle()
            }
        }
        .pabloListStyle()
    }

    private var loadMoreButton: some View {
        Button {
            Task { await viewModel.loadMoreSessions() }
        } label: {
            HStack {
                Spacer()
                if viewModel.isLoadingSessions {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 4)
                    Text("Loading...")
                        .font(.pabloBody(13))
                } else {
                    Text("Load More")
                        .font(.pabloBody(13))
                }
                Spacer()
            }
            .foregroundStyle(Color.pabloHoney)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Filter colors

    private func filterColor(for value: String?) -> Color {
        switch value {
        case nil: .pabloBrownDeep
        case "scheduled": .pabloSky
        case "in_progress": .pabloSage
        case "recording_complete": .pabloHoney
        case "finalized": .pabloSage
        case "cancelled": .gray
        default: .pabloBrownSoft
        }
    }
}

#Preview {
    SessionHistoryView(viewModel: SessionViewModel())
        .frame(width: 500, height: 600)
}
