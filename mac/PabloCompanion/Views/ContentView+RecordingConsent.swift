import AppKit
import CompanionSessionCore
import SwiftUI

// MARK: - The client's answer about AI-assisted notes, before arming

extension ContentView {
    /// Start from the companion's own window (the next-appointment card, or
    /// the native dashboard). A client who is clear starts at once, as before;
    /// a declined client, or one nobody has asked yet, gets the confirmation
    /// sheet instead.
    func requestStart(_ appointment: Appointment) {
        guard startingAppointmentId == nil, pendingLaunch == nil else { return }
        startingAppointmentId = appointment.id
        Task {
            let consent = await consentVM.check(
                appointmentId: appointment.id,
                patientId: appointment.patientId,
                service: sessionVM.consentService
            )
            startingAppointmentId = nil
            if consent == .clear {
                consentVM.reset()
                startSession(fromAppointmentId: appointment.id)
            } else {
                pendingLaunch = PendingLaunch(appointmentId: appointment.id, patientName: nil)
            }
        }
    }

    /// Creates the backend session for an appointment. When the server refuses
    /// because the client declined — the answer changed after the check, or
    /// was never read — nothing was created and nothing arms: the confirmation
    /// comes back with the declined message rather than a generic error.
    func createSession(fromAppointmentId appointmentId: String) async -> Session? {
        switch await sessionVM.startSessionFromAppointment(appointmentId: appointmentId) {
        case let .started(session):
            return session
        case let .declined(on):
            consentVM.showRefusal(declinedOn: on)
            pendingLaunch = PendingLaunch(appointmentId: appointmentId, patientName: nil)
            return nil
        case .failed:
            return nil
        }
    }

    func confirmationSheet(for launch: PendingLaunch) -> some View {
        SessionConfirmationView(
            patientName: launch.patientName,
            consent: consentVM.consent,
            isCheckingConsent: consentVM.isChecking,
            isSavingConsent: consentVM.isSaving,
            consentError: consentVM.saveError,
            scriptRetentionDays: consentVM.scriptRetentionDays,
            onStartRecording: { confirmPendingLaunch() },
            onAgreedToday: { agreedToday() },
            onOpenChart: consentVM.patientId.map { patientId in { openChart(patientId: patientId) } },
            onCancel: {
                pendingLaunch = nil
                consentVM.reset()
            }
        )
    }

    /// "Client agreed today": save the answer, then arm. A failed save stays on
    /// the sheet with its message; nothing arms.
    private func agreedToday() {
        Task {
            guard await consentVM.recordAgreedToday(service: sessionVM.consentService) else { return }
            confirmPendingLaunch()
        }
    }

    /// The client's chart in the web app, where a declined answer can be changed.
    private func openChart(patientId: String) {
        let url = webDashboardURL
            .appendingPathComponent("patients")
            .appendingPathComponent(patientId)
        pendingLaunch = nil
        consentVM.reset()
        NSWorkspace.shared.open(url)
    }
}
