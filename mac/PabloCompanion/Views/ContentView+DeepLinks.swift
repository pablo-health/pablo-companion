import SwiftUI

extension ContentView {
    /// Consumes a pending `pablohealth://` URL once auth is ready and no recording
    /// is active. Cold-launch flow: `.onOpenURL` fires before auth restore, so this
    /// also runs from `.onChange(of: authVM.authState)` when state hits `.authenticated`.
    func drainPendingDeepLink() {
        guard case .authenticated = authVM.authState else { return }
        guard let url = deepLinks.pendingURL else { return }

        if activeSessionId != nil {
            DeepLinkRouter.logger.info("Ignoring deep link while session is active")
            deepLinks.pendingURL = nil
            return
        }

        switch DeepLinkAction(url: url) {
        case let .startSessionFromAppointment(appointmentId):
            DeepLinkRouter.logger.info("Starting session from deep link appointment")
            selectedTab = 0
            startSession(fromAppointmentId: appointmentId)
        case let .unsupported(reason):
            DeepLinkRouter.logger.warning("Unsupported deep link: \(reason, privacy: .public)")
        }
        deepLinks.pendingURL = nil
    }
}
