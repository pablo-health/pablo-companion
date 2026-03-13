import SwiftUI

/// Modal sheet for quick-starting an ad-hoc session by selecting a patient.
struct QuickStartSheet: View {
    let patients: [Patient]
    let isLoading: Bool
    @Binding var searchText: String
    let onSelect: (Patient) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            Divider()
            patientContent
        }
        .frame(minWidth: 400, minHeight: 400)
        .background(Color.pabloCream)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Quick Start Session")
                .font(.pabloDisplay(20))
                .foregroundStyle(Color.pabloBrownDeep)
            Spacer()
            Button("Cancel") { dismiss() }
                .font(.pabloBody(13))
                .foregroundStyle(Color.pabloBrownSoft)
                .buttonStyle(.borderless)
        }
        .padding(16)
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search patients...", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                clearButton
            }
        }
        .padding(8)
        .background(Color.pabloCream)
    }

    private var clearButton: some View {
        Button {
            searchText = ""
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Clear search")
    }

    // MARK: - Content

    @ViewBuilder
    private var patientContent: some View {
        if isLoading, patients.isEmpty {
            Spacer()
            ProgressView("Loading patients...")
            Spacer()
        } else if patients.isEmpty {
            emptyState
        } else {
            patientList
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Patients",
            systemImage: "person.2",
            description: Text(
                searchText.isEmpty
                    ? "No patients found."
                    : "No patients match \"\(searchText)\"."
            )
        )
    }

    private var patientList: some View {
        List(patients) { patient in
            QuickStartPatientRow(patient: patient) {
                onSelect(patient)
                dismiss()
            }
            .pabloListRowStyle()
        }
        .pabloListStyle()
    }
}

// MARK: - Patient Row

/// Compact patient row for the quick-start picker.
private struct QuickStartPatientRow: View {
    let patient: Patient
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                initialsAvatar
                Text(displayName)
                    .font(.pabloBody(14))
                    .foregroundStyle(Color.pabloBrownDeep)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .cardBackground()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start session with \(displayName)")
    }

    private var initialsAvatar: some View {
        ZStack {
            Circle()
                .fill(Color.pabloHoney.opacity(0.18))
                .frame(width: 32, height: 32)
            Text(initials)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.pabloBrownDeep)
        }
    }

    private var displayName: String {
        let raw = patient.fullName
        guard raw.contains(", ") else { return raw.capitalized }
        let parts = raw.components(separatedBy: ", ")
        guard parts.count >= 2 else { return raw.capitalized }
        return [parts[1], parts[0]]
            .map(\.capitalized)
            .joined(separator: " ")
    }

    private var initials: String {
        let words = displayName.split(separator: " ").map(String.init)
        if let first = words.first?.first, let last = words.last?.first, words.count >= 2 {
            return "\(first)\(last)".uppercased()
        }
        if let word = words.first {
            return String(word.prefix(2)).uppercased()
        }
        return "?"
    }
}

// MARK: - Preview

private enum QuickStartPreviewData {
    static let patients: [Patient] = [
        Patient(
            id: "1", userId: "u1", firstName: "Jane", lastName: "Smith",
            email: "jane@example.com", phone: nil, status: "active",
            dateOfBirth: nil, diagnosis: nil, sessionCount: 12,
            lastSessionDate: nil, nextSessionDate: nil, createdAt: "", updatedAt: ""
        ),
        Patient(
            id: "2", userId: "u2", firstName: "Bob", lastName: "Jones",
            email: nil, phone: nil, status: "active",
            dateOfBirth: nil, diagnosis: nil, sessionCount: 5,
            lastSessionDate: nil, nextSessionDate: nil, createdAt: "", updatedAt: ""
        ),
    ]
}

#Preview {
    QuickStartSheet(
        patients: QuickStartPreviewData.patients,
        isLoading: false,
        searchText: .constant(""),
        onSelect: { _ in }
    )
}
