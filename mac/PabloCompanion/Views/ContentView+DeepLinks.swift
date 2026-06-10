import SwiftUI

/// A web-handoff that has cleared the redemption checkpoint and is awaiting the
/// therapist's explicit "Start Recording" confirmation. Identifiable so it can
/// drive a `.sheet(item:)`. `patientName` is PHI and is only rendered in the
/// confirmation view — never logged.
struct PendingLaunch: Identifiable, Equatable {
    let id = UUID()
    let appointmentId: String
    let patientName: String?
}

extension ContentView {
    /// Consumes a pending deep-link URL once auth is ready and no recording is
    /// active. Cold-launch flow: `.onOpenURL` / `.onContinueUserActivity` fire
    /// before auth restore, so this also runs from `.onChange(of: authVM.authState)`
    /// when state hits `.authenticated`.
    ///
    /// Launch intents (`https://<host>/launch/<id>` and the legacy
    /// `pablohealth://session/start?intent=<id>`) are redeemed through the backend
    /// checkpoint and then routed to the affirmative confirmation gate — the mic
    /// never arms from the external trigger alone. A bare `appointment=` pointer
    /// with no intent is spoofable PHI and is **never** resolved; it shows the
    /// soft expired-link state instead.
    func drainPendingDeepLink() {
        guard case .authenticated = authVM.authState else { return }
        guard let url = deepLinks.pendingURL else { return }

        if activeSessionId != nil {
            DeepLinkRouter.logger.info("Ignoring deep link while session is active")
            deepLinks.pendingURL = nil
            return
        }

        let action = DeepLinkAction(url: url)
        // Clear the buffer immediately so a redemption in-flight isn't re-triggered
        // by an unrelated state change.
        deepLinks.pendingURL = nil

        switch action {
        case let .redeemLaunchIntent(intentId):
            DeepLinkRouter.logger.info("Redeeming launch intent from deep link")
            Task { await redeemAndConfirm(intentId: intentId) }
        case .expiredPointer:
            // Raw appointment pointer with no verified intent — spoofable, never
            // resolved. Surface the soft expired-link state and let the therapist
            // re-launch from the authenticated dashboard.
            DeepLinkRouter.logger.info("Ignoring unverified appointment pointer; showing expired-link state")
            launchError = "This link has expired — start again from the dashboard."
        case let .unsupported(reason):
            DeepLinkRouter.logger.warning("Unsupported deep link: \(reason, privacy: .public)")
        }
    }

    /// Redeems the intent against the backend, then presents the confirmation gate
    /// on success. Failures surface a non-PHI message; a `410` is treated as a
    /// benign "already handed off / expired".
    private func redeemAndConfirm(intentId: String) async {
        switch await sessionVM.redeemLaunchIntent(intentId: intentId) {
        case let .confirm(context):
            pendingLaunch = PendingLaunch(
                appointmentId: context.appointmentId,
                patientName: context.patientName
            )
        case .expired:
            launchError = "This link has expired — start again from the dashboard."
        case let .failed(message):
            launchError = message
        }
    }

    /// Arms recording for a confirmed handoff. Called ONLY from the confirmation
    /// view's explicit "Start Recording" tap — this is the consent gate.
    func confirmPendingLaunch() {
        guard let launch = pendingLaunch else { return }
        pendingLaunch = nil
        selectedTab = 0
        startSession(fromAppointmentId: launch.appointmentId)
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

        // A redeemed-but-unconfirmed handoff carries the patient name (PHI) in
        // its in-flight state; purge it on sign-out alongside everything else.
        pendingLaunch = nil
        launchError = nil
    }
}
