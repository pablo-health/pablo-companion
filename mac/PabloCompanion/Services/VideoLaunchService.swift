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

        // Validate the link is an allowed HTTPS URL before any platform dispatch.
        // Done here (inline) so CodeQL dataflow can prove the URL is HTTPS.
        guard let httpsURL = validatedHTTPSVideoURL(link) else {
            logger.error("Blocked video URL for session \(session.id): not an allowed HTTPS domain")
            return
        }

        switch platform {
        case .zoom:
            launchZoom(httpsURL: httpsURL, sessionId: session.id)
        case .teams:
            launchTeams(httpsURL: httpsURL, sessionId: session.id)
        case .meet:
            launchBrowser(httpsURL: httpsURL, sessionId: session.id)
        case .none:
            break
        }
    }

    // MARK: - Platform Launchers

    private static func launchZoom(httpsURL: URL, sessionId: String) {
        // Build the zoommtg:// deep link. This is a local app handoff, not a network transmission.
        let meetingId = extractZoomMeetingId(from: httpsURL)
        let deepLink = "zoommtg://zoom.us/join?confno=\(meetingId)"

        if let url = URL(string: deepLink), url.scheme == "zoommtg" {
            logger.info("Launching Zoom for session \(sessionId)")
            NSWorkspace.shared.open(url)
        } else {
            // Fall back to browser if the deep-link URL is invalid.
            launchBrowser(httpsURL: httpsURL, sessionId: sessionId)
        }
    }

    private static func launchTeams(httpsURL: URL, sessionId: String) {
        // Convert the validated https:// Teams link to an msteams:// deep link.
        // This is a local app handoff, not a network transmission.
        let teamsLink = httpsURL.absoluteString.replacingOccurrences(
            of: "https://",
            with: "msteams://"
        )

        if let url = URL(string: teamsLink), url.scheme == "msteams" {
            logger.info("Launching Teams for session \(sessionId)")
            NSWorkspace.shared.open(url)
        } else {
            launchBrowser(httpsURL: httpsURL, sessionId: sessionId)
        }
    }

    private static func launchBrowser(httpsURL: URL, sessionId: String) {
        // httpsURL is validated by validatedHTTPSVideoURL before reaching here.
        guard httpsURL.scheme == "https" else {
            logger.error("Refusing to open non-HTTPS URL for session \(sessionId)")
            return
        }
        logger.info("Opening video link in browser for session \(sessionId)")
        NSWorkspace.shared.open(httpsURL)
    }

    // MARK: - Domain Validation

    private static let allowedVideoHosts: Set<String> = [
        "zoom.us", "us02web.zoom.us", "us04web.zoom.us", "us05web.zoom.us", "us06web.zoom.us",
        "teams.microsoft.com", "teams.live.com",
        "meet.google.com",
    ]

    /// Parses the given string and returns it as a URL only if:
    /// - It parses successfully,
    /// - Its scheme is `https`, and
    /// - Its host is a known video platform domain.
    ///
    /// Returning a URL from a single guard lets CodeQL's dataflow analysis prove
    /// that every use of the returned URL is over HTTPS.
    private static func validatedHTTPSVideoURL(_ link: String) -> URL? {
        guard let url = URL(string: link),
              url.scheme == "https",
              let host = url.host?.lowercased(),
              allowedVideoHosts.contains(host) || host.hasSuffix(".zoom.us")
        else { return nil }
        return url
    }

    // MARK: - URL Parsing

    /// Extracts the Zoom meeting ID from a URL like `https://zoom.us/j/123456789`.
    private static func extractZoomMeetingId(from url: URL) -> String {
        let pathComponents = url.pathComponents
        guard let jIndex = pathComponents.firstIndex(of: "j"),
              jIndex + 1 < pathComponents.count
        else {
            return url.absoluteString
        }
        return pathComponents[jIndex + 1]
    }
}
