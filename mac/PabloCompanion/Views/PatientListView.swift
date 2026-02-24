import SwiftUI

/// Displays a searchable list of patients fetched from the backend.
struct PatientListView: View {
    @Bindable var viewModel: PatientViewModel

    var body: some View {
        VStack(spacing: 0) {
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
            .background(.bar)

            Divider()

            if viewModel.isLoading && viewModel.patients.isEmpty {
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
                }
            }
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
}

struct PatientRow: View {
    let patient: Patient

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(patient.fullName)
                    .font(.headline)

                HStack(spacing: 12) {
                    if let email = patient.email {
                        Label(email, systemImage: "envelope")
                    }
                    Label(
                        "\(patient.sessionCount) sessions",
                        systemImage: "calendar.badge.clock"
                    )
                    if let lastSession = patient.lastSessionDate {
                        Label(lastSession, systemImage: "clock")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            Text(patient.status.capitalized)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(statusColor.opacity(0.15))
                .foregroundStyle(statusColor)
                .clipShape(Capsule())
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch patient.status.lowercased() {
        case "active": return .green
        case "inactive": return .gray
        case "discharged": return .orange
        default: return .secondary
        }
    }
}
