import SwiftUI

/// Main view combining recording controls, recording list, and settings.
struct ContentView: View {
    @State private var authVM = AuthViewModel()
    @State private var sessionVM = SessionViewModel()
    @State private var recordingVM = RecordingViewModel()
    @State private var uploadVM = UploadViewModel()
    @State private var patientVM = PatientViewModel()
    @State private var transcriptionVM = TranscriptionViewModel()
    @State private var viewingTranscript: TranscriptViewerItem?
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
            recorderTab
            patientsTab
            settingsTab
        }
        .frame(minWidth: 500, minHeight: 600)
        .task { await configureAndLoad() }
        .alert(
            "Recording Error",
            isPresented: $recordingVM.showError,
            presenting: recordingVM.errorMessage
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
        .alert(
            "Upload Error",
            isPresented: $uploadVM.showError,
            presenting: uploadVM.errorMessage
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
        .alert(
            "Patient Error",
            isPresented: $patientVM.showError,
            presenting: patientVM.errorMessage
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
        .onChange(of: uploadVM.backendURL) { _, newURL in
            patientVM.backendURL = newURL
            sessionVM.backendURL = newURL
        }
    }

    // MARK: - Setup

    private func configureAndLoad() async {
        // Discover backend URL from the auth server's /api/config.
        // Read auth server URL from Keychain (source of truth) since
        // @AppStorage doesn't persist reliably with @Observable.
        let serverURL = KeychainManager.getToken(forKey: .authServerURL)
            ?? authVM.authServerURL
        if let config = try? await fetchServerConfig(
            authServerURL: serverURL
        ) {
            uploadVM.backendURL = config.apiUrl
            patientVM.backendURL = config.apiUrl
            sessionVM.backendURL = config.apiUrl
            if KeychainManager.getToken(forKey: .firebaseAPIKey) == nil {
                if let key = config.firebaseApiKey, !key.isEmpty {
                    KeychainManager.saveToken(key, forKey: .firebaseAPIKey)
                }
            }
        }

        // Wire up token injection for authenticated requests
        uploadVM.configureAuth { [authVM] in
            try await authVM.getValidToken()
        }
        patientVM.configureAuth { [authVM] in
            try await authVM.getValidToken()
        }
        sessionVM.configureAuth { [authVM] in
            try await authVM.getValidToken()
        }

        // Eagerly refresh token on startup to catch expired sessions early
        do {
            _ = try await authVM.getValidToken()
        } catch {
            authVM.signOut()
        }

        // Load patients now that auth is configured
        await patientVM.loadPatients()
        await recordingVM.loadAudioSources()
        await uploadVM.checkBackendHealth()

        // Configure transcription VM with backend + auth
        transcriptionVM.backendURL = uploadVM.backendURL
        transcriptionVM.configureAuth { [authVM] in
            try await authVM.getValidToken()
        }

        // Retry any transcripts that failed to upload last session
        await transcriptionVM.retryPendingUploads()
    }

    // MARK: - Tabs

    private var todayTab: some View {
        DayView(sessionVM: sessionVM)
            .tabItem {
                Label("Today", systemImage: "calendar")
            }
            .tag(0)
    }

    private var recorderTab: some View {
        VStack(spacing: 0) {
            RecordingControlsView(
                state: recordingVM.recordingState,
                duration: recordingVM.duration,
                micLevel: recordingVM.micLevel,
                systemLevel: recordingVM.systemLevel,
                systemAudioActive: recordingVM.systemAudioActive,
                onStart: {
                    Task { await recordingVM.startRecording() }
                },
                onPause: { recordingVM.pauseRecording() },
                onResume: { recordingVM.resumeRecording() },
                onStop: {
                    Task { await recordingVM.stopRecording() }
                }
            )

            Divider()

            recordingList
        }
        .background(Color.pabloCream)
        .tabItem {
            Label("Recorder", systemImage: "waveform")
        }
        .tag(1)
    }

    private var recordingList: some View {
        RecordingListView(
            recordings: recordingVM.recordings,
            uploadProgress: uploadVM.uploadProgress,
            uploadingIDs: uploadVM.uploadingRecordingIDs,
            playingRecordingID: recordingVM.playingRecordingID,
            transcriptionStates: transcriptionVM.states,
            onUpload: { recording in
                Task {
                    await uploadVM.uploadRecording(recording) { uploadedID in
                        if let index = recordingVM.recordings.firstIndex(
                            where: { $0.id == uploadedID }
                        ) {
                            recordingVM.recordings[index].isUploaded = true
                        }
                    }
                }
            },
            onPlay: { recording in
                recordingVM.playRecording(recording)
            },
            onStopPlayback: {
                recordingVM.stopPlayback()
            },
            onViewTranscript: { recording in
                if let text = transcriptionVM.states[recording.id]?.transcript {
                    viewingTranscript = TranscriptViewerItem(
                        id: recording.id,
                        text: text,
                        recordingDate: recording.createdAt
                    )
                }
            },
            onTranscribe: { recording in
                Task { await transcriptionVM.transcribe(recording) }
            }
        )
        .sheet(item: $viewingTranscript) { (item: TranscriptViewerItem) in
            TranscriptViewerView(transcript: item.text, recordingDate: item.recordingDate)
        }
        .task {
            recordingVM.onRecordingCompleted = { recording in
                transcriptionVM.transcribeIfNeeded(recording)
            }
        }
    }

    private var patientsTab: some View {
        PatientListView(viewModel: patientVM)
            .tabItem {
                Label("Patients", systemImage: "person.2")
            }
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
            onCheckHealth: {
                Task { await uploadVM.checkBackendHealth() }
            },
            onGenerateTestTone: {
                recordingVM.generateTestTone()
            },
            onSignOut: {
                authVM.signOut()
            }
        )
        .tabItem {
            Label("Settings", systemImage: "gear")
        }
        .tag(3)
    }
}
