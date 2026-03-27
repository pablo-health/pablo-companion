import CoreGraphics
import Foundation

/// Monitors system-wide user input idle time for HIPAA-compliant session timeout.
///
/// Two triggers:
/// 1. **Idle timeout** — 15 minutes with no mouse/keyboard/scroll input
/// 2. **Screen lock** — immediate sign-out via `com.apple.screenIsLocked` notification
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

    /// Observes macOS screen lock and calls the handler when the screen is locked.
    /// Returns the observer token — caller must hold a reference to keep it alive.
    static func observeScreenLock(handler: @escaping () -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { _ in
            handler()
        }
    }
}
