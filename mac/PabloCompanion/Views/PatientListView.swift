import SwiftUI

/// Displays a searchable list of patients fetched from the backend.
struct PatientListView: View {
    @Bindable var viewModel: PatientViewModel

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            patientContent
        }
        .safeAreaInset(edge: .bottom) {
            if !viewModel.debugStatus.isEmpty {
                Text(viewModel.debugStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
        .onAppear {
            Task { await viewModel.loadPatients() }
        }
        .task(id: viewModel.searchText) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await viewModel.loadPatients()
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search patients...", text: $viewModel.searchText)
                .textFieldStyle(.plain)
            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(8)
        .background(Color.pabloCream)
    }

    @ViewBuilder
    private var patientContent: some View {
        if viewModel.isLoading, viewModel.patients.isEmpty {
            Spacer()
            ProgressView("Loading patients...")
            Spacer()
        } else if viewModel.patients.isEmpty {
            ContentUnavailableView(
                "No Patients",
                systemImage: "person.2",
                description: Text(
                    viewModel.searchText.isEmpty
                        ? "No patients found."
                        : "No patients match \"\(viewModel.searchText)\"."
                )
            )
        } else {
            List(viewModel.patients) { patient in
                PatientRow(patient: patient)
                    .pabloListRowStyle()
            }
            .pabloListStyle()
        }
    }
}

struct PatientRow: View {
    let patient: Patient

    var body: some View {
        HStack(spacing: 12) {
            initialsAvatar
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.pabloDisplay(15))
                    .foregroundStyle(Color.pabloBrownDeep)

                HStack(spacing: 12) {
                    if let email = patient.email {
                        Label(email, systemImage: "envelope")
                    }
                    Label(
                        "\(patient.sessionCount) sessions",
                        systemImage: "calendar.badge.clock"
                    )
                    if let dateLabel = formattedLastSession {
                        Label(dateLabel, systemImage: "clock")
                    }
                }
                .font(.pabloBody(12))
                .foregroundStyle(Color.pabloBrownSoft)
                .lineLimit(1)
            }

            Spacer()

            Text(patient.status.capitalized)
                .font(.pabloBody(12))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(statusColor.opacity(0.15))
                .foregroundStyle(statusColor)
                .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .cardBackground()
    }

    // MARK: - Subviews

    private var initialsAvatar: some View {
        ZStack {
            Circle()
                .fill(Color.pabloHoney.opacity(0.18))
                .frame(width: 36, height: 36)
            Text(initials)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.pabloBrownDeep)
        }
    }

    // MARK: - Helpers

    /// Reformats "lastname, firstname" to "Firstname Lastname".
    private var displayName: String {
        formatPatientName(patient.fullName)
    }

    /// Derives two-letter initials from the display name.
    private var initials: String {
        let words = displayName.split(separator: " ").map(String.init)
        if words.count >= 2 {
            if let first = words.first?.first, let last = words.last?.first {
                return "\(first)\(last)".uppercased()
            }
        }
        if let word = words.first {
            let chars = word.prefix(2)
            return chars.uppercased()
        }
        return "?"
    }

    /// Formats the ISO last-session date string to "MMM d, yyyy", or nil if absent.
    private var formattedLastSession: String? {
        formatISODate(patient.lastSessionDate)
    }

    private var statusColor: Color {
        switch patient.status.lowercased() {
        case "active": .pabloSage
        case "inactive": .gray
        case "discharged": .pabloBlush
        default: .secondary
        }
    }
}

// MARK: - Pure formatting helpers

/// Converts "lastname, firstname" to "Firstname Lastname". Falls back to `.capitalized`.
private func formatPatientName(_ raw: String) -> String {
    guard raw.contains(", ") else {
        return raw.capitalized
    }
    let parts = raw.components(separatedBy: ", ")
    guard parts.count >= 2 else {
        return raw.capitalized
    }
    // parts[0] = last name, parts[1] = first name
    let reordered = [parts[1], parts[0]]
    return reordered
        .map(\.capitalized)
        .joined(separator: " ")
}

/// Parses an ISO 8601 date string and formats it as "MMM d, yyyy".
private func formatISODate(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let iso = ISO8601DateFormatter()
    if let date = iso.date(from: raw) {
        let df = DateFormatter()
        df.dateFormat = "MMM d, yyyy"
        return df.string(from: date)
    }
    // ISO8601DateFormatter requires a time zone designator; try without
    let isoNoTZ = ISO8601DateFormatter()
    isoNoTZ.formatOptions = [
        .withInternetDateTime,
        .withDashSeparatorInDate,
        .withColonSeparatorInTime,
        .withFullDate,
    ]
    if let date = isoNoTZ.date(from: raw) {
        let df = DateFormatter()
        df.dateFormat = "MMM d, yyyy"
        return df.string(from: date)
    }
    return raw
}

#Preview {
    PatientListView(viewModel: PatientViewModel())
        .frame(width: 500, height: 600)
}
