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

        await patientVM.loadPatients()
        await recordingVM.loadAudioSources()
        await uploadVM.checkBackendHealth()

        transcriptionVM.backendURL = uploadVM.backendURL
        transcriptionVM.configureAuth { [authVM] in try await authVM.getValidToken() }
        await transcriptionVM.retryPendingUploads()
    }

    // MARK: - Session orchestration

    private func startSession(_ session: Session) {
        Task {
            guard await sessionVM.startSession(session.id) != nil else { return }
            await recordingVM.startRecording()
            VideoLaunchService.launch(session: session)
        }
    }

    private func handleQuickStart(_ patient: Patient) {
        Task {
            guard await sessionVM.createAdHocSession(patientId: patient.id) != nil else { return }
            await recordingVM.startRecording()
        }
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
            onStartSession: { startSession($0) },
            onQuickStart: { handleQuickStart($0) },
            onStopRecording: { Task { await recordingVM.stopRecording() } }
        )
        .tabItem { Label("Today", systemImage: "calendar") }
        .tag(0)
    }

    private var sessionsTab: some View {
        SessionHistoryView(viewModel: sessionVM)
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
