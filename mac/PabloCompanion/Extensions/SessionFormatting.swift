import SwiftUI

/// Shared formatting helpers for session display — used by SessionDetailView and other views.
enum SessionFormatting {
    static func dateString(_ scheduledAt: String?) -> String {
        guard let scheduledAt else { return "" }
        if let date = parseISO8601(scheduledAt) {
            return date.formatted(date: .long, time: .omitted)
        }
        return ""
    }

    static func timeString(_ scheduledAt: String?) -> String {
        guard let scheduledAt else { return "--:--" }
        if let date = parseISO8601(scheduledAt) {
            let df = DateFormatter()
            df.dateFormat = "h:mm a"
            return df.string(from: date)
        }
        return "--:--"
    }

    static func platformName(_ platform: VideoPlatform) -> String {
        switch platform {
        case .zoom: "Zoom"
        case .teams: "Teams"
        case .meet: "Google Meet"
        case .none: ""
        }
    }

    static func sessionTypeName(_ type: SessionType) -> String {
        switch type {
        case .individual: "Individual"
        case .couples: "Couples"
        }
    }

    static func statusLabel(_ status: SessionStatus) -> String {
        switch status {
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

    static func statusBackground(_ status: SessionStatus) -> Color {
        switch status {
        case .scheduled: Color.pabloSky.opacity(0.2)
        case .inProgress: Color.pabloSage.opacity(0.2)
        case .recordingComplete, .queued, .processing: Color.pabloHoney.opacity(0.2)
        case .pendingReview: Color.pabloHoney.opacity(0.3)
        case .finalized: Color.pabloSage.opacity(0.15)
        case .cancelled, .failed: Color.pabloBlush.opacity(0.3)
        }
    }

    static func statusForeground(_ status: SessionStatus) -> Color {
        switch status {
        case .scheduled: Color.pabloSky
        case .inProgress: Color.pabloSage
        case .recordingComplete, .queued, .processing: Color.pabloHoney
        case .pendingReview: .orange
        case .finalized: Color.pabloSage
        case .cancelled, .failed: .red
        }
    }

    static func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
