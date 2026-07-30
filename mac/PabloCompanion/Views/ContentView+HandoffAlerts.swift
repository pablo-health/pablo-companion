import SwiftUI

/// Alerts that must present in **both** shells — the thin handoff window and the
/// full native dashboard.
///
/// These previously hung off the dashboard shell only. With
/// `enableNativeDashboard` off (the default), a failed `startRecording` — system
/// audio permission denied on macOS 26, say — set `showError` with nothing
/// listening: the backend session was already marked in-progress, the app
/// returned to its idle window, and the therapist had no signal that no audio
/// was being captured. Silent audio loss during a real session is the worst
/// failure this app has, so the alerts live on the unconditional shell.
struct HandoffAlerts: ViewModifier {
    @Bindable var recordingVM: RecordingViewModel
    @Bindable var sessionVM: SessionViewModel

    func body(content: Content) -> some View {
        content
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
                "Session Error",
                isPresented: $sessionVM.showError,
                presenting: sessionVM.errorMessage
            ) { _ in
                Button("OK") {}
            } message: { message in
                Text(message)
            }
    }
}

extension View {
    /// Applies the alerts both shells need. See ``HandoffAlerts``.
    func handoffAlerts(
        recordingVM: RecordingViewModel,
        sessionVM: SessionViewModel
    ) -> some View {
        modifier(HandoffAlerts(recordingVM: recordingVM, sessionVM: sessionVM))
    }
}
