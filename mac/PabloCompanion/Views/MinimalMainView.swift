import AppKit
import SwiftUI

/// The thin-client main window (shown when `enableNativeDashboard` is false).
///
/// The web app is the dashboard; this window exists only to show connection
/// status, hand the user back to the web dashboard, and expose account /
/// preferences / version in a footer. Sized ~480×360 to be glanced at, not
/// lived in. No tabs, no session/patient lists.
struct MinimalMainView: View {
    private enum Layout {
        static let pageInset: CGFloat = 32
        static let sectionSpacing: CGFloat = 16
        static let cardRadius: CGFloat = 12
        static let bearSize: CGFloat = 68
    }

    let email: String
    let webDashboardURL: URL
    let isBackendReachable: Bool
    let micReady: Bool
    let appVersion: String
    let appointments: [Appointment]
    let appointmentsLoading: Bool
    let appointmentsError: String?
    let activeSessionId: String?
    let recordingState: RecordingUIState
    let recordingDuration: TimeInterval
    let micLevel: Float
    let systemLevel: Float
    let systemAudioActive: Bool
    let onStartAppointment: (Appointment) -> Void
    let onPauseRecording: () -> Void
    let onResumeRecording: () -> Void
    let onEndSession: () -> Void
    let onRetryAppointments: () -> Void
    let onOpenDashboard: () -> Void
    let onOpenPreferences: () -> Void
    let onSignOut: () -> Void

    /// Host shown in the status line, derived from the dashboard URL.
    private var host: String {
        webDashboardURL.host ?? "Pablo"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            header
            TimelineView(.periodic(from: .now, by: 60)) { context in
                if appointmentsLoading, appointments.isEmpty {
                    appointmentsLoadingCard
                        .padding(.top, Layout.sectionSpacing)
                } else if appointmentsError != nil, appointments.isEmpty {
                    appointmentsErrorCard
                        .padding(.top, Layout.sectionSpacing)
                } else if let appointment = Self.nextAppointment(in: appointments, now: context.date) {
                    nextAppointmentCard(appointment)
                        .padding(.top, Layout.sectionSpacing)
                } else {
                    noAppointmentsCard
                        .padding(.top, Layout.sectionSpacing)
                }
            }
            Spacer(minLength: Layout.sectionSpacing)
            Button(action: onOpenDashboard) {
                Label("Open Web Dashboard", systemImage: "safari")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.horizontal, Layout.pageInset)
            .accessibilityLabel("Open Pablo web dashboard")
            Spacer(minLength: Layout.sectionSpacing)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.pabloCream)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: Layout.bearSize, height: Layout.bearSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Pablo Companion")
                    .font(.pabloDisplay(22).weight(.bold))
                    .foregroundStyle(Color.pabloBrownDeep)
                Text("Pablo’s ready for your next session.")
                    .font(.pabloBody(14))
                    .foregroundStyle(Color.pabloBrownSoft)
            }
        }
        .padding(.horizontal, 24)
    }

    /// Connection + mic readiness. Lives in the footer with the other
    /// ambient chrome so the appointment card owns the middle of the window.
    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            statusRow(
                ok: isBackendReachable,
                okText: "Connected to \(host) as \(email)",
                offText: "Not connected to \(host)"
            )
            statusRow(
                ok: micReady,
                okText: "Microphone ready",
                offText: "Microphone permission needed"
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func nextAppointmentCard(_ appointment: Appointment) -> some View {
        VStack(spacing: 14) {
            appointmentSummary(appointment)
            appointmentAction(appointment)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous)
                .fill(Color.pabloHoney.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous)
                        .stroke(Color.pabloHoney.opacity(0.3), lineWidth: 1)
                }
        )
        .padding(.horizontal, Layout.pageInset)
    }

    /// Which action the appointment card offers. Extracted so the nil-vs-nil
    /// trap below stays covered by tests: an appointment with no session and no
    /// active recording are BOTH `nil`, and a bare `==` reads that as "this is
    /// the recording in flight" — showing Stop Recording on a session that was
    /// never started, whose button then no-ops.
    enum AppointmentAction: Equatable {
        case start
        case stopRecording
        case alreadyStarted
    }

    static func action(for appointment: Appointment, activeSessionId: String?) -> AppointmentAction {
        guard let sessionId = appointment.sessionId else { return .start }
        return sessionId == activeSessionId ? .stopRecording : .alreadyStarted
    }

    @ViewBuilder
    private func appointmentAction(_ appointment: Appointment) -> some View {
        switch Self.action(for: appointment, activeSessionId: activeSessionId) {
        case .stopRecording:
            recordingPanel(appointment)
        case .alreadyStarted:
            Label("Session started", systemImage: "checkmark.circle.fill")
                .font(.pabloBody(14).weight(.semibold))
                .foregroundStyle(Color.pabloSage)
        case .start:
            Button { onStartAppointment(appointment) } label: {
                Label("Start Session", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Color.pabloHoney)
            .accessibilityLabel("Start session for \(appointment.title)")
        }
    }

    /// Live capture state plus the two controls a therapist needs mid-session:
    /// pause (a brief hold — the session stays open) and end session (stop,
    /// upload, close). Mirrors the full dashboard's recording banner.
    private func recordingPanel(_ appointment: Appointment) -> some View {
        VStack(spacing: 12) {
            captureStatusRow
            StatusIndicator(
                isActive: systemAudioActive,
                activeLabel: "System audio",
                inactiveLabel: "No system audio"
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            recordingButtons(appointment)
        }
    }

    private var captureStatusRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(recordingState == .paused ? Color.pabloHoney : Color.pabloSage)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(captureStateLabel)
                .font(.pabloBody(13).weight(.medium))
                .foregroundStyle(Color.pabloBrownDeep)
            Text(Self.formattedDuration(recordingDuration))
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color.pabloBrownSoft)
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                LevelMeter(label: "Mic", level: micLevel)
                LevelMeter(label: "Sys", level: systemLevel)
            }
            .frame(height: 30)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(captureStateLabel), \(Self.spokenDuration(recordingDuration))")
    }

    private var captureStateLabel: String {
        recordingState == .paused ? "Paused" : "Recording"
    }

    private func recordingButtons(_ appointment: Appointment) -> some View {
        HStack(spacing: 10) {
            pauseResumeButton
            Button(role: .destructive, action: onEndSession) {
                Label("End Session", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Color.pabloError)
            .accessibilityLabel("End session for \(appointment.title)")
        }
    }

    @ViewBuilder
    private var pauseResumeButton: some View {
        if recordingState == .paused {
            Button(action: onResumeRecording) {
                Label("Resume", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityLabel("Resume recording")
        } else {
            Button(action: onPauseRecording) {
                Label("Pause", systemImage: "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityLabel("Pause recording")
        }
    }

    private func appointmentSummary(_ appointment: Appointment) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.title2)
                .foregroundStyle(Color.pabloHoney)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(Self.timingLabel(appointment, now: .now)) · \(Self.formattedTime(appointment.startAt))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.pabloBrownSoft)
                Text(appointment.title.isEmpty ? "Upcoming appointment" : appointment.title)
                    .font(.pabloDisplay(16))
                    .foregroundStyle(Color.pabloBrownDeep)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text("\(appointment.durationMinutes) min")
                .font(.caption)
                .foregroundStyle(Color.pabloBrownSoft)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Next appointment, \(appointment.title), at \(Self.formattedTime(appointment.startAt))"
        )
    }

    private var noAppointmentsCard: some View {
        Label("You’re all caught up for today.", systemImage: "checkmark.circle.fill")
            .font(.headline)
            .foregroundStyle(Color.pabloBrownDeep)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous)
                    .fill(Color.pabloSage.opacity(0.12))
            )
            .padding(.horizontal, Layout.pageInset)
    }

    private var appointmentsLoadingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Checking today’s appointments…")
                .font(.pabloBody(14))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .padding(.horizontal, Layout.pageInset)
    }

    private var appointmentsErrorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Pablo couldn’t load today’s appointments.", systemImage: "exclamationmark.triangle.fill")
                .font(.pabloBody(14).weight(.semibold))
                .foregroundStyle(Color.pabloBrownDeep)
            Button("Try Again", action: onRetryAppointments)
                .accessibilityLabel("Try loading today’s appointments again")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous)
                .fill(Color.pabloError.opacity(0.1))
        )
        .padding(.horizontal, Layout.pageInset)
    }

    static func nextAppointment(in appointments: [Appointment], now: Date) -> Appointment? {
        appointments
            .compactMap { appointment -> (appointment: Appointment, start: Date)? in
                guard appointment.status.lowercased() != "cancelled",
                      let start = parseDate(appointment.startAt),
                      let end = parseDate(appointment.endAt),
                      end >= now
                else {
                    return nil
                }
                return (appointment, start)
            }
            .min { $0.start < $1.start }?
            .appointment
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func formattedDuration(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// VoiceOver reads "12:34" as a time of day; spell the elapsed time out.
    static func spokenDuration(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration))
        return "\(total / 60) minutes \(total % 60) seconds elapsed"
    }

    private static func formattedTime(_ value: String) -> String {
        guard let date = parseDate(value) else { return "Time unavailable" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private static func timingLabel(_ appointment: Appointment, now: Date) -> String {
        guard let start = parseDate(appointment.startAt) else { return "UPCOMING" }
        return start <= now ? "IN PROGRESS" : "NEXT UP"
    }

    private func statusRow(ok: Bool, okText: String, offText: String) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(ok ? Color.pabloSage : Color.pabloError)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(ok ? okText : offText)
                .font(.pabloBody(12))
                .foregroundStyle(Color.pabloBrownDeep)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusBlock
            Divider()
            footerLinks
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.35))
    }

    private var footerLinks: some View {
        HStack(spacing: 16) {
            Button("Preferences", action: onOpenPreferences)
                .buttonStyle(.link)
                .accessibilityLabel("Open Pablo preferences")
            Button("Sign Out", role: .destructive, action: onSignOut)
                .buttonStyle(.link)
                .accessibilityLabel("Sign out of Pablo Companion")
            Spacer()
            Text("v\(appVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Version \(appVersion)")
        }
    }
}

// MARK: - Previews

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

private func previewView(
    appointment: Appointment,
    activeSessionId: String?,
    recordingState: RecordingUIState
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
        recordingState: recordingState,
        recordingDuration: 754,
        micLevel: 0.62,
        systemLevel: 0.31,
        systemAudioActive: true,
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
