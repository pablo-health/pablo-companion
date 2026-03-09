import SwiftUI

/// A single session row for the day view — shows patient name, time, status badge, and video platform.
struct SessionRowView: View {
    let session: Session

    var body: some View {
        HStack(spacing: 12) {
            // Initials avatar (matches PatientRow style)
            initialsAvatar

            // Time
            VStack(alignment: .leading, spacing: 2) {
                Text(formattedTime)
                    .font(.pabloBody(14).weight(.medium))
                    .foregroundStyle(Color.pabloBrownDeep)
                Text(durationLabel)
                    .font(.pabloBody(12))
                    .foregroundStyle(Color.pabloBrownSoft)
            }
            .frame(width: 72, alignment: .leading)

            Divider()
                .frame(height: 32)

            // Patient name + notes
            VStack(alignment: .leading, spacing: 2) {
                Text(patientName)
                    .font(.pabloDisplay(15))
                    .foregroundStyle(Color.pabloBrownDeep)
                    .lineLimit(1)
                if let notes = session.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.pabloBody(12))
                        .foregroundStyle(Color.pabloBrownSoft)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Video platform icon
            if let platform = session.videoPlatform {
                videoPlatformIcon(platform)
            }

            // Status badge
            statusBadge
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

    /// Honey by default; sage when in progress (matches branding: sage = active session).
    private var avatarColor: Color {
        session.status == .inProgress ? Color.pabloSage : Color.pabloHoney
    }

    private var initials: String {
        guard let patient = session.patient else { return "?" }
        let first = patient.firstName.first.map(String.init) ?? ""
        let last = patient.lastName.first.map(String.init) ?? ""
        return "\(first)\(last)".uppercased()
    }

    // MARK: - Status badge

    private var statusBadge: some View {
        Text(statusLabel)
            .font(.pabloBody(12))
            .foregroundStyle(statusForeground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(statusBackground)
            .clipShape(Capsule())
    }

    private var statusLabel: String {
        switch session.status {
        case .scheduled: "Scheduled"
        case .inProgress: "In Progress"
        case .recordingComplete: "Complete"
        case .queued: "Queued"
        case .processing: "Processing"
        case .pendingReview: "Review"
        case .finalized: "Finalized"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        }
    }

    private var statusBackground: Color {
        switch session.status {
        case .scheduled: Color.pabloSky.opacity(0.2)
        case .inProgress: Color.pabloSage.opacity(0.2)
        case .recordingComplete, .queued, .processing: Color.pabloHoney.opacity(0.2)
        case .pendingReview: Color.pabloHoney.opacity(0.3)
        case .finalized: Color.pabloSage.opacity(0.15)
        case .cancelled, .failed: Color.pabloBlush.opacity(0.3)
        }
    }

    private var statusForeground: Color {
        switch session.status {
        case .scheduled: Color.pabloSky
        case .inProgress: Color.pabloSage
        case .recordingComplete, .queued, .processing: Color.pabloHoney
        case .pendingReview: .orange
        case .finalized: Color.pabloSage
        case .cancelled, .failed: .red
        }
    }

    // MARK: - Video platform

    private func videoPlatformIcon(_ platform: VideoPlatform) -> some View {
        Group {
            switch platform {
            case .zoom:
                Image(systemName: "video.fill")
                    .foregroundStyle(Color.pabloSky)
            case .teams:
                Image(systemName: "person.2.fill")
                    .foregroundStyle(Color.pabloSky)
            case .meet:
                Image(systemName: "globe")
                    .foregroundStyle(Color.pabloSky)
            case .none:
                EmptyView()
            }
        }
        .font(.pabloBody(12))
    }

    // MARK: - Formatting

    private var patientName: String {
        if let patient = session.patient {
            return "\(patient.firstName) \(patient.lastName)"
        }
        return "Unknown Patient"
    }

    private var formattedTime: String {
        guard let scheduledAt = session.scheduledAt,
              let date = ISO8601DateFormatter().date(from: scheduledAt)
        else {
            return "--:--"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    private var durationLabel: String {
        "\(session.durationMinutes) min"
    }
}

// MARK: - Preview helpers

enum PreviewData {
    static let scheduled = Session(
        id: "1",
        patientId: "p1",
        patient: PatientSummary(id: "p1", firstName: "Jane", lastName: "Doe"),
        status: .scheduled,
        scheduledAt: ISO8601DateFormatter().string(from: Date()),
        startedAt: nil,
        endedAt: nil,
        durationMinutes: 50,
        videoLink: "https://zoom.us/j/123",
        videoPlatform: .zoom,
        sessionType: .individual,
        source: .companion,
        notes: nil,
        createdAt: ISO8601DateFormatter().string(from: Date()),
        updatedAt: ISO8601DateFormatter().string(from: Date())
    )

    static let inProgress = Session(
        id: "2",
        patientId: "p2",
        patient: PatientSummary(id: "p2", firstName: "John", lastName: "Smith"),
        status: .inProgress,
        scheduledAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)),
        startedAt: nil,
        endedAt: nil,
        durationMinutes: 50,
        videoLink: nil,
        videoPlatform: nil,
        sessionType: .couples,
        source: .web,
        notes: "Couples session",
        createdAt: ISO8601DateFormatter().string(from: Date()),
        updatedAt: ISO8601DateFormatter().string(from: Date())
    )
}

#Preview {
    VStack(spacing: 8) {
        SessionRowView(session: PreviewData.scheduled)
        SessionRowView(session: PreviewData.inProgress)
    }
    .padding()
    .background(Color.pabloCream)
}
