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
    /// Appointment whose session is being created/started but isn't recording
    /// yet. Pinned like a live recording so the card can't skip ahead mid-start.
    let startingAppointmentId: String?
    let recordingState: RecordingUIState
    let recordingDuration: TimeInterval
    let micLevel: Float
    let systemLevel: Float
    let systemAudioActive: Bool
    let clientAudioStatus: ClientAudioMonitor.Status
    let showsClientAudioWarning: Bool
    let onDismissClientAudioWarning: () -> Void
    /// A stalled or stopped capture in the open session; see `RecordingTrouble`.
    var recordingTrouble: RecordingTrouble?
    var uploadBacklog = UploadBacklog()
    var isUploadingNow = false
    var onRestartRecording: () -> Void = {}
    var onUploadNow: () -> Void = {}
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
                appointmentSection(now: context.date)
                    .padding(.top, Layout.sectionSpacing)
            }
            if uploadBacklog.waiting > 0 {
                UploadBacklogNote(backlog: uploadBacklog, isUploading: isUploadingNow, onUploadNow: onUploadNow)
                    .padding(.horizontal, Layout.pageInset)
                    .padding(.top, 10)
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

    /// Card selection. A recording in flight wins over every other state —
    /// including a failed refresh — because this window holds the only End
    /// Session button, and hiding it strands a live recording.
    private func appointmentSection(now: Date) -> some View {
        VStack(spacing: 10) {
            if let elsewhere = Self.inProgressElsewhere(
                in: appointments,
                now: now,
                activeSessionId: activeSessionId,
                startingAppointmentId: startingAppointmentId
            ) {
                InProgressElsewhereNote(title: elsewhere.title)
                    .padding(.horizontal, Layout.pageInset)
            }
            appointmentCard(now: now)
        }
    }

    @ViewBuilder
    private func appointmentCard(now: Date) -> some View {
        if let appointment = Self.nextAppointment(
            in: appointments,
            now: now,
            activeSessionId: activeSessionId,
            startingAppointmentId: startingAppointmentId
        ) {
            nextAppointmentCard(appointment)
        } else if activeSessionId != nil {
            untrackedRecordingCard
        } else if appointmentsLoading, appointments.isEmpty {
            appointmentsLoadingCard
        } else if appointmentsError != nil, appointments.isEmpty {
            appointmentsErrorCard
        } else {
            noAppointmentsCard
        }
    }

    /// Recording is live but its appointment isn't in today's list — a handoff
    /// for another day, or a list that failed to refresh. Show the controls
    /// anyway; the therapist still has to be able to end the session.
    private var untrackedRecordingCard: some View {
        honeyCard {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.title2)
                    .foregroundStyle(Color.pabloHoney)
                    .accessibilityHidden(true)
                Text("Session in progress")
                    .font(.pabloDisplay(16))
                    .foregroundStyle(Color.pabloBrownDeep)
                Spacer(minLength: 0)
            }
            recordingPanel(title: nil)
        }
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
        honeyCard {
            appointmentSummary(appointment)
            appointmentAction(appointment)
        }
    }

    private func honeyCard(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 14) {
            content()
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

    @ViewBuilder
    private func appointmentAction(_ appointment: Appointment) -> some View {
        switch Self.action(
            for: appointment,
            activeSessionId: activeSessionId,
            startingAppointmentId: startingAppointmentId
        ) {
        case .stopRecording:
            recordingPanel(title: appointment.title)
        case .starting:
            Button {} label: {
                Label("Starting session…", systemImage: "hourglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Color.pabloHoney)
            .disabled(true)
            .accessibilityLabel("Starting session for \(appointment.title)")
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
    private func recordingPanel(title: String?) -> some View {
        VStack(spacing: 12) {
            captureStatusRow
            if let recordingTrouble {
                RecordingTroubleNote(trouble: recordingTrouble, onRestart: onRestartRecording)
            }
            ClientAudioIndicator(systemAudioActive: systemAudioActive, status: clientAudioStatus)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsClientAudioWarning {
                ClientAudioWarningBanner(onDismiss: onDismissClientAudioWarning)
            }
            recordingButtons(title: title)
        }
    }

    private var captureStatusRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(captureDotColor)
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
            // Room for the label plus a bar tall enough to read at a glance.
            .frame(height: 44)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(captureStateLabel), \(Self.spokenDuration(recordingDuration))")
    }

    private var captureStateLabel: String {
        Self.captureStateLabel(state: recordingState)
    }

    /// Read from the capture's real state, so the card never says "Recording"
    /// once capture has stopped, failed, or not yet started.
    static func captureStateLabel(state: RecordingUIState) -> String {
        switch state {
        case .recording: "Recording"
        case .paused: "Paused"
        case .idle: "Not recording"
        }
    }

    private var captureDotColor: Color {
        if recordingTrouble != nil || recordingState == .idle { return Color.pabloError }
        return recordingState == .paused ? Color.pabloHoney : Color.pabloSage
    }

    private var captureStopped: Bool {
        recordingState == .idle
    }

    private func recordingButtons(title: String?) -> some View {
        HStack(spacing: 10) {
            // Pause means nothing once capture has stopped; the note above
            // offers the restart instead.
            if !captureStopped {
                pauseResumeButton
            }
            Button(role: .destructive, action: onEndSession) {
                Label("End Session", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Color.pabloError)
            .accessibilityLabel(title.map { "End session for \($0)" } ?? "End session")
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
        NoUpcomingAppointmentsCard(cornerRadius: Layout.cardRadius)
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
