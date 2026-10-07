import AppKit
import CompanionSessionCore
import SwiftUI

// MARK: - The client's answer about AI-assisted notes, before arming

/// What to ask once recording has started, carried from the confirmation to
/// the start (the confirmation's state is reset before the start runs).
struct OnRecordingAsk: Equatable {
    let patientId: String?
    let retentionDays: Int?
    /// Where the session is; the answer is saved as given there.
    let modality: AiConsentModality
}

extension ContentView {
    /// Start from the companion's own window (the next-appointment card, or
    /// the native dashboard). A client who is clear starts at once, as before;
    /// a declined client, or one nobody has asked yet ("Start recording and ask" or "Don't
    /// record"), gets the confirmation sheet instead.
    func requestStart(_ appointment: Appointment) {
        guard startingAppointmentId == nil, pendingLaunch == nil else { return }
        startingAppointmentId = appointment.id
        Task {
            let consent = await consentVM.check(
                appointmentId: appointment.id,
                patientId: appointment.patientId,
                modality: appointment.modality,
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

    /// Creates the session for an appointment, then arms recording and opens
    /// the video call. `askingOnRecording`: the clinician asks about
    /// AI-assisted notes once recording starts; the start says so, and the
    /// script follows once recording is running.
    func startSession(fromAppointmentId appointmentId: String, askingOnRecording: OnRecordingAsk? = nil) {
        guard startingAppointmentId == nil else { return }
        startingAppointmentId = appointmentId
        Task {
            defer { startingAppointmentId = nil }
            guard let session = await createSession(
                fromAppointmentId: appointmentId,
                askingOnRecording: askingOnRecording != nil
            ) else { return }
            guard await sessionVM.startSession(session.id) != nil else { return }
            activeSessionId = session.id
            let recording = await recordingVM.startRecording(forSession: session.id)
            if !recording { activeSessionId = nil }
            if recording, let askingOnRecording {
                askVM.begin(
                    sessionId: session.id,
                    patientId: askingOnRecording.patientId,
                    retentionDays: askingOnRecording.retentionDays,
                    modality: askingOnRecording.modality
                )
            }
            VideoLaunchService.launch(session: session)
        }
    }

    /// Creates the backend session for an appointment. When the server refuses
    /// — the client declined, or is a telehealth client nobody has asked, and
    /// the answer changed after the check or was never read — nothing was
    /// created and nothing arms: the confirmation comes back with the declined
    /// message, or with "Start recording and ask" and "Don't record", rather than a generic
    /// error.
    func createSession(fromAppointmentId appointmentId: String, askingOnRecording: Bool) async -> Session? {
        switch await sessionVM.startSessionFromAppointment(
            appointmentId: appointmentId,
            askingConsentOnRecording: askingOnRecording
        ) {
        case let .started(session):
            return session
        case let .declined(on):
            consentVM.showRefusal(declinedOn: on)
            pendingLaunch = PendingLaunch(appointmentId: appointmentId, patientName: nil)
            return nil
        case .consentNeeded:
            pendingLaunch = PendingLaunch(appointmentId: appointmentId, patientName: nil)
            // Read again, so "Start recording and ask" knows the client and the practice's
            // retention window; the server has said what the answer is.
            let read = await consentVM.check(
                appointmentId: appointmentId,
                patientId: nil,
                modality: .telehealth,
                service: sessionVM.consentService
            )
            if case .askOnRecording = read { return nil }
            consentVM.showConsentNeeded()
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
            scriptRetentionDays: consentVM.scriptRetentionDays,
            onStartRecording: { confirmPendingLaunch() },
            onAskNow: { askNow() },
            onOpenChart: consentVM.patientId.map { patientId in { openChart(patientId: patientId) } },
            onCancel: {
                pendingLaunch = nil
                consentVM.reset()
            }
        )
    }

    /// The panel shown once recording has started for a client asked on it.
    func askOnRecordingSheet() -> some View {
        AskOnRecordingView(
            viewModel: askVM,
            onAnswer: { decision in answerOnRecording(decision) },
            onClose: { askVM.dismiss() }
        )
    }

    /// What the start in hand asks once recording starts, read before the
    /// confirmation is reset. `nil` unless the clinician chose to ask then.
    var pendingOnRecordingAsk: OnRecordingAsk? {
        guard let modality = consentVM.consent.askingModality else { return nil }
        return OnRecordingAsk(
            patientId: consentVM.patientId,
            retentionDays: consentVM.scriptRetentionDays,
            modality: modality
        )
    }

    /// "Start recording and ask": start, telling the server the clinician asks on the
    /// recording; the script follows once recording is running.
    private func askNow() {
        consentVM.askNow()
        confirmPendingLaunch()
    }

    /// Saves the answer given on the recording. An agreement
    /// closes the panel. A decline first stops and deletes the recording, so
    /// nothing of it is uploaded whether or not the answer saves, and the
    /// panel then says so. A failed save stays on the panel with its message.
    private func answerOnRecording(_ decision: String) {
        Task {
            if decision == AiConsentEntry.declined, !askVM.recordingDeleted, let ask = askVM.ask {
                if await discardDeclinedRecording(sessionId: ask.sessionId) {
                    askVM.markRecordingDeleted()
                }
            }
            guard await askVM.record(decision: decision, service: sessionVM.consentService) else { return }
            if decision != AiConsentEntry.declined { askVM.dismiss() }
        }
    }

    /// The client declined on the recording: stop capture, delete every
    /// segment and anything that could upload it, and return the session to
    /// a hand-written note, as a session the web starts without recording.
    /// Returns false, deleting nothing, when that session is no longer the one
    /// recording.
    private func discardDeclinedRecording(sessionId: String) async -> Bool {
        guard activeSessionId == sessionId else { return false }
        // Still the active session while capture stops, so the last segment
        // is filed under it (and never taken for a standalone recording).
        await recordingVM.stopRecording()
        recordingVM.discardDeclinedSession(sessionId, uploadStore: transcriptionVM.pendingAudioStore)
        recordingVM.activeSessionId = nil
        activeSessionId = nil
        _ = await sessionVM.returnToHandWritten(sessionId)
        await sessionVM.loadTodayAppointments()
        return true
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
