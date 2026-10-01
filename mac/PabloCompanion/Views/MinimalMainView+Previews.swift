import SwiftUI

private func previewAppointment(sessionId: String? = nil) -> Appointment {
    Appointment(
        id: "appointment",
        patientId: "patient",
        title: "Initial consultation",
        startAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(600)),
        endAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(3600)),
        durationMinutes: 50,
        status: "scheduled",
        sessionType: nil,
        videoLink: nil,
        videoPlatform: "zoom",
        notes: nil,
        icalSource: nil,
        ehrAppointmentUrl: nil,
        sessionId: sessionId,
        createdAt: ISO8601DateFormatter().string(from: .now),
        updatedAt: nil
    )
}

@MainActor
private func previewView(
    appointment: Appointment,
    activeSessionId: String?,
    recordingState: RecordingUIState,
    startingAppointmentId: String? = nil,
    clientAudioStatus: ClientAudioMonitor.Status = .hearingClient
) -> MinimalMainView {
    MinimalMainView(
        email: "therapist@pablo.health",
        webDashboardURL: URL(string: "https://app.pablo.health/dashboard") ?? URL(fileURLWithPath: "/"),
        isBackendReachable: true,
        micReady: true,
        appVersion: "1.0.0",
        appointments: [appointment],
        appointmentsLoading: false,
        appointmentsError: nil,
        activeSessionId: activeSessionId,
        startingAppointmentId: startingAppointmentId,
        recordingState: recordingState,
        recordingDuration: 754,
        micLevel: 0.62,
        systemLevel: 0.31,
        systemAudioActive: true,
        clientAudioStatus: clientAudioStatus,
        showsClientAudioWarning: clientAudioStatus == .noClientAudio,
        onDismissClientAudioWarning: {},
        onStartAppointment: { _ in },
        onPauseRecording: {},
        onResumeRecording: {},
        onEndSession: {},
        onRetryAppointments: {},
        onOpenDashboard: {},
        onOpenPreferences: {},
        onSignOut: {}
    )
}

#Preview("Ready to start") {
    previewView(
        appointment: previewAppointment(),
        activeSessionId: nil,
        recordingState: .idle
    )
    .frame(width: 520, height: 560)
}

#Preview("Recording") {
    previewView(
        appointment: previewAppointment(sessionId: "session-1"),
        activeSessionId: "session-1",
        recordingState: .recording
    )
    .frame(width: 520, height: 560)
}

#Preview("Paused") {
    previewView(
        appointment: previewAppointment(sessionId: "session-1"),
        activeSessionId: "session-1",
        recordingState: .paused
    )
    .frame(width: 520, height: 560)
}

#Preview("Starting") {
    previewView(
        appointment: previewAppointment(),
        activeSessionId: nil,
        recordingState: .idle,
        startingAppointmentId: "appointment"
    )
    .frame(width: 520, height: 560)
}

#Preview("Session ended, nothing else today") {
    previewView(
        appointment: previewAppointment(sessionId: "session-1"),
        activeSessionId: nil,
        recordingState: .idle
    )
    .frame(width: 520, height: 560)
}

#Preview("Can't hear client") {
    previewView(
        appointment: previewAppointment(sessionId: "session-1"),
        activeSessionId: "session-1",
        recordingState: .recording,
        clientAudioStatus: .noClientAudio
    )
    .frame(width: 520, height: 640)
}
