import SwiftUI

/// Main view — authenticates, then shows four-tab navigation.
struct ContentView: View {
    @State private var authVM = AuthViewModel()
    @State private var sessionVM = SessionViewModel()
    @State private var recordingVM = RecordingViewModel()
    @State private var uploadVM = UploadViewModel()
    @State private var patientVM = PatientViewModel()
    @State private var transcriptionVM = TranscriptionViewModel()
    @State private var viewingTranscript: TranscriptViewerItem?
    @State private var detailSession: Session?
    @State private var activeSessionId: String?
    @State private var selectedTab = 0

    var body: some View {
        Group {
            switch authVM.authState {
            case .unauthenticated, .authenticating, .tokenExpired:
                LoginView(authViewModel: authVM)
                    .frame(minWidth: 500, minHeight: 600)

            case .authenticated:
                authenticatedContent
            }
        }
        .background(Color.pabloCream)
        .preferredColorScheme(.light)
    }

    private var authenticatedContent: some View {
        TabView(selection: $selectedTab) {
            todayTab
            sessionsTab
            patientsTab
            settingsTab
        }
        .frame(minWidth: 500, minHeight: 600)
        .task { await configureAndLoad() }
        .alert("Recording Error", isPresented: $recordingVM.showError, presenting: recordingVM.errorMessage) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
        .alert("Upload Error", isPresented: $uploadVM.showError, presenting: uploadVM.errorMessage) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
        .alert("Patient Error", isPresented: $patientVM.showError, presenting: patientVM.errorMessage) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
        .alert("Session Error", isPresented: $sessionVM.showError, presenting: sessionVM.errorMessage) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { break }
                await transcriptionVM.retryPendingUploads()
            }
        }
        .sheet(item: $viewingTranscript) { item in
            TranscriptViewerView(transcript: item.text, recordingDate: item.recordingDate)
        }
        .sheet(item: $detailSession) { session in
            sessionDetailSheet(session)
        }
        .onChange(of: uploadVM.backendURL) { _, newURL in
            patientVM.backendURL = newURL
            sessionVM.backendURL = newURL
        }
    }

    // MARK: - Setup

    private func configureAndLoad() async {
        let serverURL = KeychainManager.getToken(forKey: .authServerURL)
            ?? authVM.authServerURL
        if let config = try? await fetchServerConfig(authServerURL: serverURL) {
            uploadVM.backendURL = config.apiUrl
            patientVM.backendURL = config.apiUrl
            sessionVM.backendURL = config.apiUrl
            if KeychainManager.getToken(forKey: .firebaseAPIKey) == nil {
                if let key = config.firebaseApiKey, !key.isEmpty {
                    KeychainManager.saveToken(key, forKey: .firebaseAPIKey)
                }
            }
        }

        uploadVM.configureAuth { [authVM] in try await authVM.getValidToken() }
        patientVM.configureAuth { [authVM] in try await authVM.getValidToken() }
        sessionVM.configureAuth { [authVM] in try await authVM.getValidToken() }

        do {
            _ = try await authVM.getValidToken()
        } catch {
            authVM.signOut()
        }

        recordingVM.restorePersistedRecordings()
        await sessionVM.loadTodaySessions()
        await patientVM.loadPatients()
        await recordingVM.loadAudioSources()
        await uploadVM.checkBackendHealth()

        transcriptionVM.backendURL = uploadVM.backendURL
        transcriptionVM.configureAuth { [authVM] in try await authVM.getValidToken() }
        await transcriptionVM.retryPendingUploads()

        recordingVM.onRecordingCompleted = { [recordingVM, transcriptionVM] recording in
            transcriptionVM.transcribeIfNeeded(recording, sessionId: recordingVM.activeSessionId)
        }

        ModelManager.shared.onModelDownloaded = { [transcriptionVM] preset in
            Task { await transcriptionVM.processAwaitingModelRecordings(downloadedPreset: preset) }
        }
    }

    // MARK: - Session orchestration

    private func startSession(_ session: Session) {
        Task {
            guard await sessionVM.startSession(session.id) != nil else { return }
            activeSessionId = session.id
            recordingVM.activeSessionId = session.id
            await recordingVM.startRecording()
            VideoLaunchService.launch(session: session)
        }
    }

    private func handleQuickStart(_ patient: Patient) {
        Task {
            guard let session = await sessionVM.createAdHocSession(patientId: patient.id) else { return }
            guard await sessionVM.startSession(session.id) != nil else { return }
            activeSessionId = session.id
            recordingVM.activeSessionId = session.id
            await recordingVM.startRecording()
        }
    }

    // MARK: - Lookups

    private func transcriptionStateForSession(_ sessionId: String) -> TranscriptionState? {
        guard let recordingId = recordingVM.sessionRecordingMap[sessionId] else {
            return nil
        }
        return transcriptionVM.states[recordingId]
    }

    private func hasRecordingForSession(_ sessionId: String) -> Bool {
        recordingVM.recordingForSession(sessionId) != nil
    }

    private func transcribeSession(_ session: Session) {
        guard let recording = recordingVM.recordingForSession(session.id) else {
            return
        }
        Task { await transcriptionVM.transcribe(recording, sessionId: session.id) }
    }

    private func showTranscript(for session: Session) {
        guard let text = transcriptionStateForSession(session.id)?.transcript
        else { return }
        let date = ISO8601DateFormatter().date(from: session.scheduledAt ?? "")
            ?? Date()
        viewingTranscript = TranscriptViewerItem(
            id: UUID(),
            text: text,
            recordingDate: date
        )
    }

    private func playSession(_ session: Session) {
        guard let recording = recordingVM.recordingForSession(session.id) else {
            return
        }
        recordingVM.playRecording(recording)
    }

    private func reuploadTranscript(for session: Session) {
        let recId = recordingVM.recordingForSession(session.id)?.id ?? UUID()
        Task {
            await transcriptionVM.reuploadTranscript(recordingId: recId, sessionId: session.id)
            await sessionVM.loadTodaySessions()
        }
    }

    private func sessionDetailSheet(_ session: Session) -> some View {
        let recording = recordingVM.recordingForSession(session.id)
        let state = transcriptionStateForSession(session.id)
        let isPlaying = recordingVM.playingSessionId == session.id
        let patient = session.patientId.flatMap { id in patientVM.patients.first { $0.id == id } }
        let isStaleInProgress = session.status == .inProgress && session.id != activeSessionId
        let orphans = recording == nil ? recordingVM.orphanedRecordings() : []
        let canReupload = session.status == .failed && state?.transcript != nil

        return SessionDetailView(
            session: session,
            patient: patient,
            recording: recording,
            transcriptionState: state,
            isPlaying: isPlaying,
            onTranscribe: recording != nil
                ? { transcribeSession(session) } : nil,
            onReuploadTranscript: canReupload
                ? { reuploadTranscript(for: session) } : nil,
            onPlay: recording != nil
                ? { playSession(session) } : nil,
            onStopPlayback: isPlaying
                ? { recordingVM.stopPlayback() } : nil,
            onEndSession: isStaleInProgress ? {
                Task {
                    _ = await sessionVM.endSession(session.id)
                    await sessionVM.loadTodaySessions()
                    detailSession = nil
                }
            } : nil,
            orphanedRecordings: orphans,
            onLinkRecording: { linked in
                recordingVM.linkRecording(linked, toSession: session.id)
                detailSession = nil
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    detailSession = session
                }
            }
        )
    }

    // MARK: - Tabs

    private var todayTab: some View {
        DayView(
            sessionVM: sessionVM,
            patients: patientVM.patients,
            isLoadingPatients: patientVM.isLoading,
            patientSearchText: $patientVM.searchText,
            recordingState: recordingVM.recordingState,
            recordingDuration: recordingVM.duration,
            pendingUploadCount: transcriptionVM.pendingUploadCount,
            awaitingModelCount: transcriptionVM.awaitingModelCount,
            transcriptionStateForSession: { transcriptionStateForSession($0) },
            hasRecordingForSession: { hasRecordingForSession($0) },
            playingSessionId: recordingVM.playingSessionId,
            onStartSession: { startSession($0) },
            onQuickStart: { handleQuickStart($0) },
            onStopRecording: {
                Task {
                    await recordingVM.stopRecording()
                    recordingVM.activeSessionId = nil
                    if let sessionId = activeSessionId {
                        _ = await sessionVM.endSession(sessionId)
                        activeSessionId = nil
                    }
                    await sessionVM.loadTodaySessions()
                }
            },
            recordingStalled: recordingVM.recordingStalled,
            recordingError: recordingVM.persistentError,
            onRetryCapture: { Task { await recordingVM.retryCapture() } },
            onDismissError: { recordingVM.persistentError = nil },
            onRetryUploads: { Task { await transcriptionVM.forceRetryPendingUploads() } },
            onSwitchToSettings: { selectedTab = 3 },
            onViewTranscript: { showTranscript(for: $0) },
            onTranscribeSession: { transcribeSession($0) },
            onPlaySession: { playSession($0) },
            onStopPlayback: { recordingVM.stopPlayback() },
            onEndSession: { session in
                Task {
                    _ = await sessionVM.endSession(session.id)
                    await sessionVM.loadTodaySessions()
                }
            },
            activeSessionId: activeSessionId,
            onSessionTapped: { detailSession = $0 }
        )
        .tabItem { Label("Today", systemImage: "calendar") }
        .tag(0)
    }

    private var sessionsTab: some View {
        SessionHistoryView(
            viewModel: sessionVM,
            patients: patientVM.patients,
            pendingUploadCount: transcriptionVM.pendingUploadCount,
            transcriptionStateForSession: { transcriptionStateForSession($0) },
            hasRecordingForSession: { hasRecordingForSession($0) },
            playingSessionId: recordingVM.playingSessionId,
            onRetryUploads: { Task { await transcriptionVM.forceRetryPendingUploads() } },
            onViewTranscript: { showTranscript(for: $0) },
            onTranscribeSession: { transcribeSession($0) },
            onPlaySession: { playSession($0) },
            onStopPlayback: { recordingVM.stopPlayback() },
            onSessionTapped: { detailSession = $0 }
        )
        .tabItem { Label("Sessions", systemImage: "list.clipboard") }
        .tag(1)
    }

    private var patientsTab: some View {
        PatientListView(viewModel: patientVM)
            .tabItem { Label("Patients", systemImage: "person.2") }
            .tag(2)
    }

    private var settingsTab: some View {
        SettingsView(
            backendURL: $uploadVM.backendURL,
            authServerURL: $authVM.authServerURL,
            selectedMicID: $recordingVM.selectedMicID,
            encryptionEnabled: $recordingVM.encryptionEnabled,
            debugEnableMic: $recordingVM.debugEnableMic,
            debugEnableSystem: $recordingVM.debugEnableSystem,
            userEmail: authVM.authenticatedEmail,
            availableMics: recordingVM.availableMics,
            isBackendReachable: uploadVM.isBackendReachable,
            bluetoothRoutingConflict: recordingVM.bluetoothRoutingConflict,
            bluetoothRecommendation: recordingVM.bluetoothRecommendation,
            systemAudioPermitted: recordingVM.systemAudioPermitted,
            recordingState: recordingVM.recordingState,
            diagnostics: recordingVM.debugDiagnostics,
            onCheckHealth: { Task { await uploadVM.checkBackendHealth() } },
            onGenerateTestTone: { recordingVM.generateTestTone() },
            onSignOut: { authVM.signOut() }
        )
        .tabItem { Label("Settings", systemImage: "gear") }
        .tag(3)
    }
}
