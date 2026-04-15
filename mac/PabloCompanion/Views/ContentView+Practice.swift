import SwiftUI

// MARK: - Practice Mode (extracted to keep ContentView under file/type length limits)

extension ContentView {
    @ViewBuilder
    var practiceSheet: some View {
        switch practiceVM.phase {
        case .idle, .loadingTopics, .pickingTopic:
            PracticeTopicSheet(
                topics: practiceVM.topics,
                isLoading: practiceVM.phase == .loadingTopics,
                onSelect: { topic in
                    Task { await practiceVM.startSession(topic: topic) }
                },
                onCancel: {
                    practiceVM.dismiss()
                    showPractice = false
                }
            )
            .task { await practiceVM.loadTopics() }

        case .connecting, .active, .ending:
            if let topic = practiceVM.selectedTopic {
                PracticeSessionView(
                    topic: topic,
                    duration: practiceVM.duration,
                    micLevel: practiceVM.micLevel,
                    pabloLevel: practiceVM.pabloLevel,
                    pabloState: practiceVM.pabloState,
                    isConnecting: practiceVM.phase == .connecting,
                    onPause: { practiceVM.pauseAudio() },
                    onResume: { practiceVM.resumeAudio() },
                    onEnd: { practiceVM.endSession() }
                )
            }

        case let .ended(durationSeconds):
            PracticeEndedView(
                topicName: practiceVM.selectedTopic?.name ?? "Practice",
                durationSeconds: durationSeconds,
                onDismiss: {
                    practiceVM.dismiss()
                    showPractice = false
                    Task { await sessionVM.loadTodayAppointments() }
                }
            )

        case let .error(message):
            PracticeEndedView(
                topicName: "Error: \(message)",
                durationSeconds: Int(practiceVM.duration),
                onDismiss: {
                    practiceVM.dismiss()
                    showPractice = false
                }
            )
        }
    }

    func startPractice() {
        guard activeSessionId == nil else { return }
        showPractice = true
    }
}
