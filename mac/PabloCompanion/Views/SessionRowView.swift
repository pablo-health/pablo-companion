import SwiftUI

/// A single session row for the day view — shows patient name, time, status badge, and video platform.
struct SessionRowView: View {
    let session: Session
    var patientLookup: ((String) -> Patient?)?
    var transcriptionState: TranscriptionState?
    var hasRecording = false
    var isPlaying = false
    var onStart: (() -> Void)?
    var onViewTranscript: (() -> Void)?
    var onTranscribe: (() -> Void)?
    var onPlay: (() -> Void)?
    var onStopPlayback: (() -> Void)?
    var onEndSession: (() -> Void)?
    @State private var isPulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            initialsAvatar
            timeColumn
            Divider().frame(height: 32)
            patientInfo
            Spacer()
            if let platform = session.videoPlatform {
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
                .overlay {
                    Circle()
                        .stroke(Color.pabloSage, lineWidth: 2)
                        .opacity(isPulsing ? 0.35 : 0.18)
                        .animation(pulseAnimation, value: isPulsing)
                        .opacity(session.status == .inProgress ? 1 : 0)
                }
            Text(initials)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.pabloBrownDeep)
        }
        .onAppear {
            if session.status == .inProgress { isPulsing = true }
        }
    }

    private var avatarColor: Color {
        session.status == .inProgress ? Color.pabloSage : Color.pabloHoney
    }

    private var initials: String {
        if let patient = session.patient {
            let first = patient.firstName.first.map(String.init) ?? ""
            let last = patient.lastName.first.map(String.init) ?? ""
            return "\(first)\(last)".uppercased()
        }
        if let id = session.patientId, let patient = patientLookup?(id) {
            let first = patient.firstName.first.map(String.init) ?? ""
            let last = patient.lastName.first.map(String.init) ?? ""
            return "\(first)\(last)".uppercased()
        }
        return "?"
    }

    private var pulseAnimation: Animation? {
        session.status == .inProgress && !reduceMotion
            ? .easeInOut(duration: 1.5).repeatForever(autoreverses: true)
            : nil
    }

    // MARK: - Time column

    private var timeColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(formattedTime)
                .font(.pabloBody(14).weight(.medium))
                .foregroundStyle(Color.pabloBrownDeep)
            Text(durationLabel)
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
            if let notes = session.notes, !notes.isEmpty {
                Text(notes)
                    .font(.pabloBody(12))
                    .foregroundStyle(Color.pabloBrownSoft)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Trailing content (button or badge)

    @ViewBuilder
    private var trailingContent: some View {
        if session.status == .scheduled, let onStart {
            startButton(onStart)
        } else if session.status == .inProgress, let onEndSession {
            endSessionButton(onEndSession)
        } else {
            HStack(spacing: 8) {
                if let action = isPlaying ? onStopPlayback : onPlay {
                    Button(action: action) {
                        Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                            .font(.pabloBody(11))
                            .foregroundStyle(Color.pabloHoney)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isPlaying ? "Stop playback" : "Play recording")
                    .help(isPlaying ? "Stop" : "Play recording")
                }
                transcriptionButton
                statusBadge
            }
        }
    }

    @ViewBuilder
    private var transcriptionButton: some View {
        switch transcriptionState {
        case nil:
            if hasRecording, let onTranscribe {
                Button("Transcribe") { onTranscribe() }
                    .font(.pabloBody(11))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .accessibilityLabel("Transcribe session for \(patientName)")
            }
        case .running:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Transcribing…")
                    .font(.pabloBody(11))
                    .foregroundStyle(.secondary)
            }
        case .awaitingModel:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Awaiting model…")
                    .font(.pabloBody(11))
                    .foregroundStyle(.secondary)
            }
        case .done, .pendingUpload:
            if let onViewTranscript {
                Button("View") { onViewTranscript() }
                    .font(.pabloBody(11))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .accessibilityLabel("View transcript")
            }
        case .failed:
            if let onTranscribe {
                Button("Retry") { onTranscribe() }
                    .font(.pabloBody(11))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(Color.pabloError)
                    .accessibilityLabel("Retry transcription")
            }
        }
    }

    private func endSessionButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("End Session")
                .font(.pabloBody(13))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.pabloError)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("End session with \(patientName)")
        .help("End this stale in-progress session")
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

    // MARK: - Status badge

    private var statusBadge: some View {
        HStack(spacing: 4) {
            if session.status == .processing || session.status == .queued {
                ProgressView().controlSize(.mini)
            }
            if session.status == .finalized {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
            }
            Text(statusLabel)
        }
        .font(.pabloBody(12))
        .foregroundStyle(statusForeground)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(statusBackground)
        .clipShape(Capsule())
        .accessibilityElement(children: .combine)
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
                    .accessibilityLabel("Zoom call")
            case .teams:
                Image(systemName: "person.2.fill")
                    .foregroundStyle(Color.pabloSky)
                    .accessibilityLabel("Teams call")
            case .meet:
                Image(systemName: "globe")
                    .foregroundStyle(Color.pabloSky)
                    .accessibilityLabel("Google Meet call")
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
        if let id = session.patientId, let patient = patientLookup?(id) {
            return "\(patient.firstName) \(patient.lastName)"
        }
        return "Unknown Patient"
    }

    private var formattedTime: String {
        guard let scheduledAt = session.scheduledAt else { return "--:--" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: scheduledAt) {
            return timeString(from: date)
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: scheduledAt) {
            return timeString(from: date)
        }
        return "--:--"
    }

    private func timeString(from date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "h:mm a"
        return df.string(from: date)
    }

    private var durationLabel: String {
        "\(session.durationMinutes ?? 0) min"
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
        SessionRowView(session: PreviewData.scheduled, onStart: {})
        SessionRowView(session: PreviewData.inProgress)
        SessionRowView(session: PreviewData.inProgress, onEndSession: {})
    }
    .padding()
    .background(Color.pabloCream)
}
