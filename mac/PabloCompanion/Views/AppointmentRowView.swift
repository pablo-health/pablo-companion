import SwiftUI

/// A single appointment row for the day view — shows patient name, time, and Start Session button.
struct AppointmentRowView: View {
    let appointment: Appointment
    var patientLookup: ((String) -> Patient?)?
    var isActiveSession: Bool = false
    var onStartSession: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            initialsAvatar
            timeColumn
            Divider().frame(height: 32)
            patientInfo
            Spacer()
            if let platform = appointment.videoPlatform, !platform.isEmpty {
                videoPlatformIcon(platform)
            }
            trailingContent
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .cardBackground()
    }

    // MARK: - Initials avatar

    private var initialsAvatar: some View {
        ZStack {
            Circle()
                .fill(avatarColor.opacity(0.18))
                .frame(width: 36, height: 36)
            Text(initials)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.pabloBrownDeep)
        }
    }

    private var avatarColor: Color {
        isActiveSession ? Color.pabloSage : Color.pabloHoney
    }

    private var initials: String {
        guard let patient = patientLookup?(appointment.patientId) else { return "?" }
        let first = patient.firstName.first.map(String.init) ?? ""
        let last = patient.lastName.first.map(String.init) ?? ""
        return "\(first)\(last)".uppercased()
    }

    // MARK: - Time column

    private var timeColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(formattedTime)
                .font(.pabloBody(14).weight(.medium))
                .foregroundStyle(Color.pabloBrownDeep)
            Text("\(appointment.durationMinutes) min")
                .font(.pabloBody(12))
                .foregroundStyle(Color.pabloBrownSoft)
        }
        .frame(width: 72, alignment: .leading)
    }

    // MARK: - Patient info

    private var patientInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(patientName)
                .font(.pabloDisplay(15))
                .foregroundStyle(Color.pabloBrownDeep)
                .lineLimit(1)
            if let source = appointment.icalSource {
                Text(source.capitalized)
                    .font(.pabloBody(12))
                    .foregroundStyle(Color.pabloBrownSoft)
                    .lineLimit(1)
            } else if let notes = appointment.notes, !notes.isEmpty {
                Text(notes)
                    .font(.pabloBody(12))
                    .foregroundStyle(Color.pabloBrownSoft)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Trailing content

    @ViewBuilder
    private var trailingContent: some View {
        if isActiveSession {
            sessionActiveBadge
        } else if appointment.sessionId != nil {
            sessionStartedBadge
        } else if let onStartSession {
            startButton(onStartSession)
        }
    }

    private func startButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Start Session")
                .font(.pabloBody(13))
                .foregroundStyle(Color.pabloBrownDeep)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.pabloHoney)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start session with \(patientName)")
    }

    private var sessionStartedBadge: some View {
        Text("Session Started")
            .font(.pabloBody(12))
            .foregroundStyle(Color.pabloSage)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.pabloSage.opacity(0.15))
            .clipShape(Capsule())
    }

    private var sessionActiveBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.pabloSage)
                .frame(width: 8, height: 8)
            Text("Recording")
                .font(.pabloBody(12))
                .foregroundStyle(Color.pabloSage)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.pabloSage.opacity(0.15))
        .clipShape(Capsule())
    }

    // MARK: - Video platform

    private func videoPlatformIcon(_ platform: String) -> some View {
        Group {
            switch platform.lowercased() {
            case "zoom":
                Image(systemName: "video.fill")
                    .accessibilityLabel("Zoom call")
            case "teams":
                Image(systemName: "person.2.fill")
                    .accessibilityLabel("Teams call")
            case "meet":
                Image(systemName: "globe")
                    .accessibilityLabel("Google Meet call")
            default:
                EmptyView()
            }
        }
        .font(.pabloBody(12))
        .foregroundStyle(Color.pabloSky)
    }

    // MARK: - Formatting

    private var patientName: String {
        guard let patient = patientLookup?(appointment.patientId) else {
            return appointment.title.isEmpty ? "Unknown Patient" : appointment.title
        }
        return "\(patient.firstName) \(patient.lastName)"
    }

    private var formattedTime: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: appointment.startAt) {
            return timeString(from: date)
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: appointment.startAt) {
            return timeString(from: date)
        }
        return "--:--"
    }

    private func timeString(from date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "h:mm a"
        return df.string(from: date)
    }
}

#Preview {
    VStack(spacing: 8) {
        AppointmentRowView(
            appointment: Appointment(
                id: "1", patientId: "p1", title: "Session",
                startAt: ISO8601DateFormatter().string(from: Date()),
                endAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(3000)),
                durationMinutes: 50, status: "confirmed",
                sessionType: "individual", videoLink: nil, videoPlatform: "zoom",
                notes: nil, icalSource: "simplepractice", ehrAppointmentUrl: nil, sessionId: nil,
                createdAt: ISO8601DateFormatter().string(from: Date()),
                updatedAt: nil
            ),
            onStartSession: {}
        )
        AppointmentRowView(
            appointment: Appointment(
                id: "2", patientId: "p2", title: "Session",
                startAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)),
                endAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(6600)),
                durationMinutes: 50, status: "confirmed",
                sessionType: "individual", videoLink: nil, videoPlatform: nil,
                notes: nil, icalSource: nil, ehrAppointmentUrl: nil,
                sessionId: "existing-session-id",
                createdAt: ISO8601DateFormatter().string(from: Date()),
                updatedAt: nil
            )
        )
    }
    .padding()
    .background(Color.pabloCream)
}
