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
        guard let linkURL = URL(string: link), isAllowedVideoDomain(linkURL) else {
            logger.error("Blocked Zoom URL for session \(sessionId): not an allowed domain")
            return
        }
        // Only a `/j/<id>` link carries a meeting number for `confno`. Personal
        // rooms (`/my/<name>`) and webinars (`/w/<id>`) have none, so hand those
        // to the browser, which redirects into the Zoom app itself.
        guard let meetingId = extractZoomMeetingId(from: link) else {
            logger.info("Zoom link has no meeting ID for session \(sessionId), opening in browser")
            launchBrowser(link: link, sessionId: sessionId)
            return
        }

        guard let url = URL(string: "zoommtg://zoom.us/join?confno=\(meetingId)") else {
            launchBrowser(link: link, sessionId: sessionId)
            return
        }
        logger.info("Launching Zoom for session \(sessionId)")
        NSWorkspace.shared.open(url)
    }

    private static func launchTeams(link: String, sessionId: String) {
        guard let linkURL = URL(string: link), isAllowedVideoDomain(linkURL) else {
            logger.error("Blocked Teams URL for session \(sessionId): not an allowed domain")
            return
        }
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
        guard let url = URL(string: link), isAllowedVideoDomain(url) else {
            logger.error("Blocked or invalid video URL for session \(sessionId)")
            return
        }
        logger.info("Opening video link in browser for session \(sessionId)")
        NSWorkspace.shared.open(url)
    }

    // MARK: - Domain Validation

    private static let allowedVideoHosts: Set<String> = [
        "zoom.us", "us02web.zoom.us", "us04web.zoom.us", "us05web.zoom.us", "us06web.zoom.us",
        "teams.microsoft.com", "teams.live.com",
        "meet.google.com",
    ]

    /// Returns true if the URL's host is a known video platform domain.
    private static func isAllowedVideoDomain(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return allowedVideoHosts.contains(host)
            || host.hasSuffix(".zoom.us")
    }

    // MARK: - URL Parsing

    /// Extracts the numeric Zoom meeting ID from a URL like `https://zoom.us/j/123456789`.
    ///
    /// Returns `nil` when the link carries no `/j/<numeric-id>` path — personal
    /// rooms, webinars, and vanity links have no meeting number, and `confno`
    /// is interpolated into a URL string, so a non-numeric component must never
    /// reach it.
    ///
    /// Internal rather than private so `VideoLaunchServiceTests` can cover the
    /// URL shapes directly; `NSWorkspace.open` is not reachable from a test.
    static func extractZoomMeetingId(from link: String) -> String? {
        guard let url = URL(string: link) else { return nil }
        let pathComponents = url.pathComponents
        guard let jIndex = pathComponents.firstIndex(of: "j"),
              jIndex + 1 < pathComponents.count
        else {
            return nil
        }
        let meetingId = pathComponents[jIndex + 1]
        guard !meetingId.isEmpty, meetingId.allSatisfy(\.isNumber) else { return nil }
        return meetingId
    }
}
