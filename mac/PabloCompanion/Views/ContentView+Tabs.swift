import SwiftUI

// MARK: - Native dashboard tabs

/// The four-tab native dashboard surfaces. Live only when
/// `enableNativeDashboard` is true; kept intact (not deleted) so the full-fat
/// desktop experience is one flag flip away.
extension ContentView {
    var todayTab: some View {
        DayView(
            sessionVM: sessionVM,
            patients: patientVM.patients,
            isLoadingPatients: patientVM.isLoading,
            patientSearchText: $patientVM.searchText,
            recordingState: recordingVM.recordingState,
            recordingDuration: recordingVM.duration,
            micLevel: recordingVM.micLevel,
            systemLevel: recordingVM.systemLevel,
            systemAudioActive: recordingVM.systemAudioActive,
            pendingUploadCount: transcriptionVM.pendingUploadCount,
            transcriptionStateForSession: { transcriptionStateForSession($0) },
            hasRecordingForSession: { hasRecordingForSession($0) },
            playingSessionId: recordingVM.playingSessionId,
            onStartSession: { startSession(fromAppointmentId: $0.id) },
            onQuickStart: { handleQuickStart($0) },
            onStopRecording: {
                Task {
                    await recordingVM.stopRecording()
                    let sessionId = activeSessionId
                    recordingVM.activeSessionId = nil
                    activeSessionId = nil
                    if let sessionId {
                        _ = await sessionVM.endSession(sessionId)
                        let segments = recordingVM.allRecordingsForSession(sessionId)
                        if !segments.isEmpty {
                            await transcriptionVM.uploadAudioSegments(segments, sessionId: sessionId)
                        }
                        recordingVM.clearSessionSegments(sessionId)
                    }
                    await sessionVM.loadTodayAppointments()
                }
            },
            recordingStalled: recordingVM.recordingStalled,
            recordingError: recordingVM.persistentError,
            onRetryCapture: { Task { await recordingVM.retryCapture() } },
            onDismissError: { recordingVM.persistentError = nil },
            onRetryUploads: { Task { await forceRetryAllPendingUploads() } },
            onSwitchToSettings: { selectedTab = 3 },
            onViewTranscript: { showTranscript(for: $0) },
            onTranscribeSession: { transcribeSession($0) },
            onPlaySession: { playSession($0) },
            onStopPlayback: { recordingVM.stopPlayback() },
            onEndSession: { session in
                Task {
                    _ = await sessionVM.endSession(session.id)
                    await sessionVM.loadTodayAppointments()
                }
            },
            activeSessionId: activeSessionId,
            onSessionTapped: { appointment in
                guard let sessionId = appointment.sessionId else { return }
                detailSession = sessionVM.todaySessions.first { $0.id == sessionId }
            }
        )
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    startPractice()
                } label: {
                    Label("Practice", systemImage: "pawprint.fill")
                }
                .disabled(activeSessionId != nil || practiceVM.isSessionActive)
                .accessibilityLabel("Start practice session with Pablo Bear")
            }
        }
        .tabItem { Label("Today", systemImage: "calendar") }
        .tag(0)
    }

    var sessionsTab: some View {
        SessionHistoryView(
            viewModel: sessionVM,
            patients: patientVM.patients,
            pendingUploadCount: transcriptionVM.pendingUploadCount,
            transcriptionStateForSession: { transcriptionStateForSession($0) },
            hasRecordingForSession: { hasRecordingForSession($0) },
            playingSessionId: recordingVM.playingSessionId,
            onRetryUploads: { Task { await forceRetryAllPendingUploads() } },
            onViewTranscript: { showTranscript(for: $0) },
            onTranscribeSession: { transcribeSession($0) },
            onPlaySession: { playSession($0) },
            onStopPlayback: { recordingVM.stopPlayback() },
            onSessionTapped: { detailSession = $0 }
        )
        .tabItem { Label("Sessions", systemImage: "list.clipboard") }
        .tag(1)
    }

    var patientsTab: some View {
        PatientListView(viewModel: patientVM)
            .tabItem { Label("Patients", systemImage: "person.2") }
            .tag(2)
    }
}
