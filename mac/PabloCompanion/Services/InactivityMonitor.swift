import CoreGraphics
import Foundation

/// Monitors system-wide user input idle time for HIPAA-compliant session timeout.
///
/// Polls `CGEventSource` to detect how long since the last mouse/keyboard/scroll
/// event. No special permissions required — uses the combined session state.
enum InactivityMonitor {
    /// Lock the app after 15 minutes of inactivity.
    static let timeoutSeconds: TimeInterval = 15 * 60

    /// Seconds since the last user input event (mouse, keyboard, click, or scroll).
    static func systemIdleSeconds() -> TimeInterval {
        let events: [CGEventType] = [.mouseMoved, .keyDown, .leftMouseDown, .scrollWheel]
        return events.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min() ?? 0
    }
}
