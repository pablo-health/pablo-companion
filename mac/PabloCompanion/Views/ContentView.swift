import SwiftUI

/// Main view — authenticates, then shows four-tab navigation.
struct ContentView: View {
    var authVM: AuthViewModel
    var deepLinks: DeepLinkRouter
    @State var sessionVM = SessionViewModel()
    @State private var recordingVM = RecordingViewModel()
    @State private var uploadVM = UploadViewModel()
    @State private var patientVM = PatientViewModel()
    @State private var transcriptionVM = TranscriptionViewModel()
    @State var practiceVM = PracticeViewModel()
    @State private var subscriptionVM = SubscriptionViewModel()
    @State var showPractice = false
    @State private var viewingTranscript: TranscriptViewerItem?
    @State private var detailSession: Session?
    @State var activeSessionId: String?
    @State var selectedTab = 0
    @State private var versionBlock: UpdateRequiredView.Reason?
    @State private var screenLockObserver: NSObjectProtocol?

    var body: some View {
        Group {
            if let reason = versionBlock {
                UpdateRequiredView(reason: reason)
                    .frame(minWidth: 500, minHeight: 600)
            } else {
                switch authVM.authState {
                case .unauthenticated, .authenticating, .tokenExpired:
                    LoginView(authViewModel: authVM)
                        .frame(minWidth: 500, minHeight: 600)

                case .authenticated:
                    authenticatedContent
                }
            }
        }
        .background(Color.pabloCream)
        .preferredColorScheme(.light)
    }

    private var authenticatedContent: some View {
        VStack(spacing: 0) {
            SubscriptionBannerView(viewModel: subscriptionVM)
            TabView(selection: $selectedTab) {
                todayTab
                sessionsTab
                patientsTab
                settingsTab
            }
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
        .task {
            // Subscription status refresh — every 10 minutes.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                guard !Task.isCancelled else { break }
                await subscriptionVM.refreshStatus()
            }
        }
        .task {
            // HIPAA inactivity timeout — lock after 15 minutes of no user input.
            // Skip if a session is actively recording (therapist is talking, not at keyboard).
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                let isIdle = InactivityMonitor.systemIdleSeconds() >= InactivityMonitor.timeoutSeconds
                if activeSessionId == nil, isIdle {
                    authVM.signOut()
                }
            }
        }
        .onAppear {
            screenLockObserver = InactivityMonitor.observeScreenLock { [authVM] in
                // Don't sign out during an active recording session
                guard activeSessionId == nil else { return }
                authVM.signOut()
            }
        }
        .sheet(item: $viewingTranscript) { item in
            TranscriptViewerView(transcript: item.text, recordingDate: item.recordingDate)
        }
        .sheet(item: $detailSession) { session in
            sessionDetailSheet(session)
        }
        .onChange(of: authVM.authState) { _, newState in
            if case .unauthenticated = newState {
                clearAllPHI()
            }
            if case .authenticated = newState {
                drainPendingDeepLink()
            }
        }
        .onChange(of: deepLinks.pendingURL) { _, url in
            guard url != nil else { return }
            drainPendingDeepLink()
        }
        .onChange(of: uploadVM.backendURL) { _, newURL in
            patientVM.backendURL = newURL
            sessionVM.backendURL = newURL
            practiceVM.backendURL = newURL
            subscriptionVM.backendURL = newURL
        }
        .onChange(of: sessionVM.subscriptionBlocked) { _, blocked in
            if blocked {
                Task { await subscriptionVM.refreshStatus() }
                sessionVM.subscriptionBlocked = false
            }
        }
        .sheet(isPresented: $showPractice) {
            practiceSheet
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
            subscriptionVM.backendURL = config.apiUrl
            if KeychainManager.getToken(forKey: .firebaseAPIKey) == nil {
                if let key = config.firebaseApiKey, !key.isEmpty {
                    KeychainManager.saveToken(key, forKey: .firebaseAPIKey)
                }
            }
        }

        uploadVM.configureAuth { [authVM] in try await authVM.getValidToken() }
        patientVM.configureAuth { [authVM] in try await authVM.getValidToken() }
        sessionVM.configureAuth { [authVM] in try await authVM.getValidToken() }
        practiceVM.configureAuth { [authVM] in try await authVM.getValidToken() }
        subscriptionVM.configureAuth { [authVM] in try await authVM.getValidToken() }

        // Scope encryption keys to the signed-in user
        let email = authVM.authenticatedEmail
        recordingVM.userEmail = email
        transcriptionVM.userEmail = email

        do {
            _ = try await authVM.getValidToken()
        } catch {
            authVM.signOut()
        }

        recordingVM.restorePersistedRecordings()
        await sessionVM.loadTodayAppointments()
        await patientVM.loadPatients()
        await recordingVM.loadAudioSources()
        await uploadVM.checkBackendHealth()
        checkVersionCompatibility()

        transcriptionVM.backendURL = uploadVM.backendURL
        transcriptionVM.configureAuth { [authVM] in try await authVM.getValidToken() }
        await transcriptionVM.retryPendingUploads()
        await adoptAndRetryPendingAudioUploads()
        await subscriptionVM.refreshStatus()

        recordingVM.onRecordingCompleted = { [recordingVM, transcriptionVM] recording in
            // Only auto-transcribe standalone recordings (no active session).
            // Session recordings are transcribed after the session ends via onStopRecording.
            if recordingVM.activeSessionId == nil {
                transcriptionVM.transcribeIfNeeded(recording)
            }
        }

    }

    /// On launch, sweep the recordings directory for orphaned audio whose
    /// recording-ID maps back to a known session via `sessionRecordingMap`,
    /// enqueue them into `PendingAudioUploadStore`, and drive the retry loop.
    /// Mirrors the Windows scanner + `ResumePendingUploadsAsync` (App.xaml.cs:190-212).
    /// Orphans without a session linkage stay in the existing manual-attach UX.
    private func adoptAndRetryPendingAudioUploads() async {
        let orphans = recordingVM.orphanedRecordings()
        if !orphans.isEmpty {
            let recordingToSession = Dictionary(
                uniqueKeysWithValues: recordingVM.sessionRecordingMap.map { ($1, $0) }
            )
            for orphan in orphans {
                guard let sessionId = recordingToSession[orphan.id] else { continue }
                guard let micURL = orphan.micPCMFileURL else { continue }
                transcriptionVM.enqueuePendingAudioUpload(
                    sessionId: sessionId,
                    micPath: micURL.path,
                    systemPath: orphan.systemPCMFileURL?.path,
                    isEncrypted: orphan.isEncrypted
                )
            }
        }
        await transcriptionVM.retryPendingAudioUploads()
    }

    private func checkVersionCompatibility() {
        guard let status = uploadVM.lastHealthStatus else { return }
        if status.clientUpdateRequired {
            versionBlock = .clientUpdate(
                currentVersion: AppConstants.appVersion,
                minVersion: status.minClientVersion
            )
        } else if status.serverUpdateRequired {
            versionBlock = .serverUpdate(
                serverVersion: status.serverVersion,
                minRequired: status.minServerVersion
            )
        }
    }

    // MARK: - Session orchestration

    func startSession(fromAppointmentId appointmentId: String) {
        Task {
            guard let session = await sessionVM.startSessionFromAppointment(
                appointmentId: appointmentId
            ) else { return }
            guard await sessionVM.startSession(session.id) != nil else { return }
            activeSessionId = session.id
            recordingVM.activeSessionId = session.id
            await recordingVM.startRecording()
            VideoLaunchService.launch(session: session)
        }
    }

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
        transcriptionVM.transcribeIfNeeded(recording, sessionId: session.id)
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
            await sessionVM.loadTodayAppointments()
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
                    await sessionVM.loadTodayAppointments()
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
            onRetryUploads: {
                Task {
                    await transcriptionVM.forceRetryPendingUploads()
                    await transcriptionVM.forceRetryPendingAudioUploads()
                }
            },
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

    private var sessionsTab: some View {
        SessionHistoryView(
            viewModel: sessionVM,
            patients: patientVM.patients,
            pendingUploadCount: transcriptionVM.pendingUploadCount,
            transcriptionStateForSession: { transcriptionStateForSession($0) },
            hasRecordingForSession: { hasRecordingForSession($0) },
            playingSessionId: recordingVM.playingSessionId,
            onRetryUploads: {
                Task {
                    await transcriptionVM.forceRetryPendingUploads()
                    await transcriptionVM.forceRetryPendingAudioUploads()
                }
            },
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

}

// MARK: - Settings Tab

extension ContentView {
    var settingsTab: some View {
        SettingsView(
            backendURL: $uploadVM.backendURL,
            authServerURL: Bindable(authVM).authServerURL,
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

// MARK: - PHI Cleanup

extension ContentView {
    /// Clears all PHI from in-memory ViewModels on sign-out.
    func clearAllPHI() {
        sessionVM.todaySessions = []
        sessionVM.sessions = []
        sessionVM.totalSessions = 0
        sessionVM.hasMoreSessions = false
        sessionVM.errorMessage = nil

        recordingVM.recordings = []
        recordingVM.sessionRecordingMap = [:]
        recordingVM.activeSessionId = nil
        recordingVM.stopPlayback()
        recordingVM.userEmail = nil

        transcriptionVM.states = [:]
        transcriptionVM.pendingUploadCount = 0
        transcriptionVM.errorMessage = nil
        transcriptionVM.userEmail = nil

        patientVM.patients = []
        patientVM.searchText = ""

        practiceVM.dismiss()

        subscriptionVM.subscriptionInfo = nil
        subscriptionVM.extensionError = nil

        activeSessionId = nil
        detailSession = nil
        viewingTranscript = nil
    }
}
