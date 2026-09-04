import SwiftUI

// MARK: - Settings Tab

extension ContentView {
    /// `SettingsView` is a bare `Form` — fine as a tab, but a macOS sheet has no
    /// chrome of its own, so presented from the minimal window it had no way
    /// out. The Done button (and Escape) is that way out.
    var preferencesSheet: some View {
        VStack(spacing: 0) {
            settingsTab
            Divider()
            HStack {
                Spacer()
                Button("Done") { showPreferences = false }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Close preferences")
            }
            .padding(12)
            .background(Color.pabloCream)
        }
        .frame(minWidth: 460, minHeight: 520)
        .onExitCommand { showPreferences = false }
    }

    var settingsTab: some View {
        SettingsView(
            backendURL: $uploadVM.backendURL,
            authServerURL: Bindable(authVM).authServerURL,
            selectedMicID: $recordingVM.selectedMicID,
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
