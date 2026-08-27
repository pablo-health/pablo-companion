import Foundation
@testable import Pablo
import Testing

/// Covers Zoom meeting-ID extraction, the input to the `zoommtg://` deep link.
///
/// A link with no `/j/<id>` path previously returned the whole URL, producing
/// `zoommtg://zoom.us/join?confno=https://zoom.us/my/room` — a deep link Zoom
/// cannot honour, with an unreachable browser fallback. Personal rooms are the
/// common setup for recurring appointments, so these shapes must resolve to
/// `nil` and route to the browser instead.
@Suite("VideoLaunchService Zoom meeting ID")
struct VideoLaunchServiceTests {

    // MARK: - Links that carry a meeting number

    @Test func extractsIdFromStandardJoinLink() {
        #expect(VideoLaunchService.extractZoomMeetingId(from: "https://zoom.us/j/123456789") == "123456789")
    }

    @Test func extractsIdFromRegionalHost() {
        #expect(
            VideoLaunchService.extractZoomMeetingId(from: "https://us02web.zoom.us/j/98765432100")
                == "98765432100"
        )
    }

    @Test func extractsIdWhenPasscodeQueryPresent() {
        // Real invites carry ?pwd=... — the query must not leak into confno.
        #expect(
            VideoLaunchService.extractZoomMeetingId(from: "https://zoom.us/j/123456789?pwd=abc123")
                == "123456789"
        )
    }

    @Test func extractsIdWithTrailingSlash() {
        #expect(VideoLaunchService.extractZoomMeetingId(from: "https://zoom.us/j/123456789/") == "123456789")
    }

    // MARK: - Links with no meeting number (must route to browser)

    @Test func personalRoomReturnsNil() {
        // The regression: a therapist's personal room, the standard setup for
        // recurring weekly appointments.
        #expect(VideoLaunchService.extractZoomMeetingId(from: "https://zoom.us/my/drsmith") == nil)
    }

    @Test func webinarLinkReturnsNil() {
        #expect(VideoLaunchService.extractZoomMeetingId(from: "https://zoom.us/w/123456789") == nil)
    }

    @Test func vanityLinkReturnsNil() {
        #expect(VideoLaunchService.extractZoomMeetingId(from: "https://zoom.us/s/drsmith") == nil)
    }

    @Test func bareHostReturnsNil() {
        #expect(VideoLaunchService.extractZoomMeetingId(from: "https://zoom.us") == nil)
    }

    @Test func joinPathWithoutIdReturnsNil() {
        #expect(VideoLaunchService.extractZoomMeetingId(from: "https://zoom.us/j/") == nil)
    }

    @Test func malformedURLReturnsNil() {
        #expect(VideoLaunchService.extractZoomMeetingId(from: "not a url") == nil)
    }

    // MARK: - Non-numeric IDs must never reach the scheme string

    @Test func nonNumericIdReturnsNil() {
        // `confno` is interpolated into a URL string; a non-numeric path
        // component must not reach it.
        #expect(VideoLaunchService.extractZoomMeetingId(from: "https://zoom.us/j/room-name") == nil)
    }

    @Test func idWithSchemeInjectionAttemptReturnsNil() {
        #expect(
            VideoLaunchService.extractZoomMeetingId(from: "https://zoom.us/j/1%26pwd%3Devil")
                == nil
        )
    }
}
