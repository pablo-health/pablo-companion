import SwiftUI

/// Modal sheet for quick-starting an ad-hoc session by selecting a patient.
///
/// When the deployment's note-type catalog offers more than one
/// session-context format, a picker lets the clinician choose which
/// note the recording should generate; the selected registry key is
/// handed to `onSelect` (nil = server default).
struct QuickStartSheet: View {
    let patients: [Patient]
    let isLoading: Bool
    @Binding var searchText: String
    var noteTypes: [NoteTypeSummary] = []
    let onSelect: (Patient, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    /// Nil until the catalog arrives (or when it is empty); always a key
    /// present in `noteTypes` once set, see `reconcileSelection()`.
    @State private var selectedNoteType: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            if noteTypes.count > 1 {
                Divider()
                noteTypePicker
            }
            Divider()
            patientContent
        }
        .frame(minWidth: 400, minHeight: 400)
        .background(Color.pabloCream)
        .onChange(of: noteTypes, initial: true) { _, _ in reconcileSelection() }
    }

    /// The catalog can arrive after the sheet is shown, or change under
    /// it (backend switch); keep the selection pointing at a real entry.
    private func reconcileSelection() {
        selectedNoteType = noteTypes.resolvedSelection(current: selectedNoteType)
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

    // MARK: - Note type

    private var noteTypePicker: some View {
        HStack {
            Text("Note type")
                .font(.pabloBody(13))
                .foregroundStyle(Color.pabloBrownSoft)
            Spacer()
            Picker("Note type", selection: $selectedNoteType) {
                ForEach(noteTypes) { noteType in
                    Text(noteType.label).tag(Optional(noteType.key))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 220)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.pabloCream)
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

    private var chosenNoteType: String? {
        noteTypes.resolvedSelection(current: selectedNoteType)
    }

    private var patientList: some View {
        List(patients) { patient in
            QuickStartPatientRow(patient: patient) {
                // Only forward an explicit choice when there was a real
                // picker and it points at a catalog entry; otherwise let
                // the server apply its default.
                onSelect(patient, noteTypes.count > 1 ? chosenNoteType : nil)
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
        noteTypes: [
            NoteTypeSummary(key: "soap", label: "SOAP", context: "session", isLocked: false),
            NoteTypeSummary(
                key: "narrative", label: "Narrative", context: "session", isLocked: false
            ),
        ],
        onSelect: { _, _ in }
    )
}
