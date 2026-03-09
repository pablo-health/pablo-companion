import AppKit
import os

/// Launches video calls via platform-specific URL schemes or browser.
///
/// - Zoom: `zoommtg://zoom.us/join?confno=MEETING_ID`
/// - Teams: `msteams://` deep link
/// - Google Meet: opens in the default browser
enum VideoLaunchService {

    private static let logger = Logger(
        subsystem: AppConstants.appBundleID,
        category: "VideoLaunchService"
    )

    /// Launches the video call associated with a session.
    ///
    /// If the session has no video platform or no video link, this is a no-op.
    static func launch(session: Session) {
        guard let platform = session.videoPlatform, platform != .none else {
            logger.info("No video platform for session \(session.id), skipping launch")
            return
        }
        guard let link = session.videoLink, !link.isEmpty else {
            logger.info("No video link for session \(session.id), skipping launch")
            return
        }

        switch platform {
        case .zoom:
            launchZoom(link: link, sessionId: session.id)
        case .teams:
            launchTeams(link: link, sessionId: session.id)
        case .meet:
            launchBrowser(link: link, sessionId: session.id)
        case .none:
            break
        }
    }

    // MARK: - Platform Launchers

    private static func launchZoom(link: String, sessionId: String) {
        // Extract meeting ID from Zoom URL (e.g., https://zoom.us/j/123456789)
        let meetingId = extractZoomMeetingId(from: link)
        let scheme = "zoommtg://zoom.us/join?confno=\(meetingId)"

        if let url = URL(string: scheme) {
            logger.info("Launching Zoom for session \(sessionId)")
            NSWorkspace.shared.open(url)
        } else {
            // Fall back to browser if scheme URL is invalid
            launchBrowser(link: link, sessionId: sessionId)
        }
    }

    private static func launchTeams(link: String, sessionId: String) {
        // Convert https:// Teams link to msteams:// deep link
        let teamsLink = link.replacingOccurrences(
            of: "https://",
            with: "msteams://"
        )

        if let url = URL(string: teamsLink) {
            logger.info("Launching Teams for session \(sessionId)")
            NSWorkspace.shared.open(url)
        } else {
            launchBrowser(link: link, sessionId: sessionId)
        }
    }

    private static func launchBrowser(link: String, sessionId: String) {
        guard let url = URL(string: link) else {
            logger.error("Invalid video URL for session \(sessionId): \(link)")
            return
        }
        logger.info("Opening video link in browser for session \(sessionId)")
        NSWorkspace.shared.open(url)
    }

    // MARK: - URL Parsing

    /// Extracts the Zoom meeting ID from a URL like `https://zoom.us/j/123456789`.
    private static func extractZoomMeetingId(from link: String) -> String {
        guard let url = URL(string: link),
              let pathComponents = Optional(url.pathComponents),
              let jIndex = pathComponents.firstIndex(of: "j"),
              jIndex + 1 < pathComponents.count
        else {
            // If we can't parse it, return the whole link — Zoom may handle it
            return link
        }
        return pathComponents[jIndex + 1]
    }
}
