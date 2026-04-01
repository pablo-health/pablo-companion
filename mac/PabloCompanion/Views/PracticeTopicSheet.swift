import SwiftUI

/// Topic picker sheet — displayed when the therapist starts a practice session.
struct PracticeTopicSheet: View {
    let topics: [PracticeTopic]
    let isLoading: Bool
    let onSelect: (PracticeTopic) -> Void
    let onCancel: () -> Void

    @State private var selectedId: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isLoading {
                loadingState
            } else if topics.isEmpty {
                emptyState
            } else {
                topicList
            }

            Divider()
            footer
        }
        .frame(width: 480, height: 520)
        .background(Color.pabloCream)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Text("Practice Session")
                .font(.pabloDisplay(22))
                .foregroundStyle(Color.pabloBrownDeep)

            Text("Choose a topic for Pablo Bear's session")
                .font(.pabloBody(13))
                .foregroundStyle(Color.pabloBrownSoft)
        }
        .padding(.vertical, 20)
    }

    // MARK: - Topic list

    private var topicList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(topics) { topic in
                    topicRow(topic)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private func topicRow(_ topic: PracticeTopic) -> some View {
        let isSelected = selectedId == topic.id

        return Button {
            selectedId = topic.id
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(topic.name)
                        .font(.pabloBody(14).weight(.medium))
                        .foregroundStyle(Color.pabloBrownDeep)

                    Text(topic.description)
                        .font(.pabloBody(12))
                        .foregroundStyle(Color.pabloBrownSoft)
                        .lineLimit(2)
                }

                Spacer()

                Text("\(topic.estimatedDurationMinutes) min")
                    .font(.pabloBody(11))
                    .foregroundStyle(Color.pabloBrownSoft)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.pabloHoney.opacity(0.12) : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.pabloHoney : Color.clear, lineWidth: 2)
            )
            .shadow(color: Color.black.opacity(0.04), radius: 2, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(topic.name): \(topic.description)")
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Loading topics...")
                .font(.pabloBody(13))
                .foregroundStyle(Color.pabloBrownSoft)
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundStyle(Color.pabloBrownSoft)
                .accessibilityHidden(true)
            Text("No practice topics available")
                .font(.pabloBody(14))
                .foregroundStyle(Color.pabloBrownSoft)
            Spacer()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Cancel") { onCancel() }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Cancel practice session")

            Spacer()

            Button("Start Session") {
                guard let id = selectedId,
                      let topic = topics.first(where: { $0.id == id })
                else { return }
                onSelect(topic)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedId == nil)
            .accessibilityLabel("Start practice session with selected topic")
        }
        .padding(16)
    }
}
