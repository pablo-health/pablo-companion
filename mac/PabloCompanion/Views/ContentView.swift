import AppKit
import SwiftUI

/// Main view — authenticates, then shows either the thin handoff window (default)
/// or, behind `enableNativeDashboard`, the full four-tab native dashboard.
struct ContentView: View {
    var authVM: AuthViewModel
    var deepLinks: DeepLinkRouter
    @State var sessionVM = SessionViewModel()
    // recordingVM / transcriptionVM are non-private: ContentView+AudioRecovery
    // is a separate-file extension that drives the launch recovery + retry flow.
    @State var recordingVM = RecordingViewModel()
    @State private var uploadVM = UploadViewModel()
    @State var patientVM = PatientViewModel()
    @State var transcriptionVM = TranscriptionViewModel()
    @State var practiceVM = PracticeViewModel()
    @State private var subscriptionVM = SubscriptionViewModel()
    @State var showPractice = false
    @State private var viewingTranscript: TranscriptViewerItem?
    @State var detailSession: Session?
    @State var activeSessionId: String?
    @State var selectedTab = 0
    @State private var versionBlock: UpdateRequiredView.Reason?
    @State private var screenLockObserver: NSObjectProtocol?

    /// A web-handoff awaiting the therapist's explicit "Start Recording" tap.
    /// Set after a launch intent is redeemed (or a legacy appointment handoff is
    /// parsed); cleared when confirmed or cancelled. The mic does NOT arm while
    /// this is merely set — only the confirmation tap arms it.
    @State var pendingLaunch: PendingLaunch?

    /// Non-PHI message shown when a launch intent can't be redeemed.
    @State var launchError: String?

    /// Whether the preferences sheet is shown from the minimal window's footer.
    @State private var showPreferences = false

    /// Gates the full four-tab native dashboard. Default `false`: the companion
    /// shows only the minimal handoff window and the web app is the dashboard.
    /// Flip to `true` (UserDefaults key `enableNativeDashboard`) to restore the
    /// full native shell. No view files are deleted either way.
    @AppStorage("enableNativeDashboard") private var enableNativeDashboard = false

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

    /// Authenticated shell. The full four-tab dashboard is gated behind
    /// `enableNativeDashboard`; when off (default) the companion is a thin handoff
    /// target showing only the minimal status window. Deep-link handoff,
    /// background work, and the launch-confirmation gate run in BOTH modes.
    private var authenticatedContent: some View {
        Group {
            if enableNativeDashboard {
                nativeDashboardShell
            } else {
                minimalShell
            }
        }
        .task { await configureAndLoad() }
        .sheet(item: $pendingLaunch) { launch in
            SessionConfirmationView(
                patientName: launch.patientName,
                onStartRecording: { confirmPendingLaunch() },
                onCancel: { pendingLaunch = nil }
            )
        }
        .sheet(isPresented: launchErrorBinding) {
            LaunchIntentErrorView(
                message: launchError ?? "This link is no longer valid.",
                onDismiss: { launchError = nil }
            )
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
    }

    /// Binding that drives the launch-error sheet from the optional `launchError`.
    private var launchErrorBinding: Binding<Bool> {
        Binding(
            get: { launchError != nil },
            set: { if !$0 { launchError = nil } }
        )
    }

    /// The full four-tab native dashboard (flag on). Verbatim from the prior
    /// unconditional shell — no behaviour change when `enableNativeDashboard` is true.
    private var nativeDashboardShell: some View {
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
        .alert("Recording Error", isPresented: $recordingVM.showError, presenting: recordingVM.errorMessage) { _ in
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
        .sheet(item: $viewingTranscript) { item in
            TranscriptViewerView(transcript: item.text, recordingDate: item.recordingDate)
        }
        .sheet(item: $detailSession) { session in
            sessionDetailSheet(session)
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

    /// The thin-client minimal window (flag off, default). Status + "Open Web
    /// Dashboard" + footer. Designed to be glanced at, not lived in.
    private var minimalShell: some View {
        MinimalMainView(
            email: authVM.authenticatedEmail,
            webDashboardURL: webDashboardURL,
            isBackendReachable: uploadVM.isBackendReachable,
            micReady: recordingVM.systemAudioPermitted,
            appVersion: AppConstants.appVersion,
            onOpenDashboard: { openWebDashboard() },
            onOpenPreferences: { showPreferences = true },
            onSignOut: { authVM.signOut() }
        )
        .frame(width: 480, height: 360)
        .sheet(isPresented: $showPreferences) {
            settingsTab
                .frame(minWidth: 460, minHeight: 520)
        }
    }

    // MARK: - Web dashboard

    /// The web dashboard URL, derived from the configured auth-server (Next.js
    /// front-end) host so it tracks dev vs prod automatically — same value the
    /// OAuth flow already uses. Falls back to the prod dashboard if unset/invalid.
    var webDashboardURL: URL {
        let base = (KeychainManager.getToken(forKey: .authServerURL) ?? authVM.authServerURL)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let isValidBase = URLValidator.validateScheme(base) == nil
        if isValidBase, let url = URL(string: "\(base)/dashboard") {
            return url
        }
        // Static fallback — guaranteed to parse.
        return URL(string: "https://app.pablo.health/dashboard")
            ?? URL(fileURLWithPath: "/")
    }

    private func openWebDashboard() {
        NSWorkspace.shared.open(webDashboardURL)
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
        await resumeAllPendingUploads()
        await subscriptionVM.refreshStatus()

        recordingVM.onRecordingCompleted = { [recordingVM, transcriptionVM] recording in
            // Only auto-transcribe standalone recordings (no active session).
            // Session recordings are transcribed after the session ends via onStopRecording.
            if recordingVM.activeSessionId == nil {
                transcriptionVM.transcribeIfNeeded(recording)
            }
        }

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

    func handleQuickStart(_ patient: Patient) {
        Task {
            guard let session = await sessionVM.createAdHocSession(patientId: patient.id) else { return }
            guard await sessionVM.startSession(session.id) != nil else { return }
            activeSessionId = session.id
            recordingVM.activeSessionId = session.id
            await recordingVM.startRecording()
        }
    }

    // MARK: - Lookups

    func transcriptionStateForSession(_ sessionId: String) -> TranscriptionState? {
        guard let recordingId = recordingVM.sessionRecordingMap[sessionId] else {
            return nil
        }
        return transcriptionVM.states[recordingId]
    }

    func hasRecordingForSession(_ sessionId: String) -> Bool {
        recordingVM.recordingForSession(sessionId) != nil
    }

    func transcribeSession(_ session: Session) {
        guard let recording = recordingVM.recordingForSession(session.id) else {
            return
        }
        transcriptionVM.transcribeIfNeeded(recording, sessionId: session.id)
    }

    func showTranscript(for session: Session) {
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

    func playSession(_ session: Session) {
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
