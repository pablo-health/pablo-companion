import ApplicationServices
import Cocoa
import Foundation
import os

// MARK: - Types

/// A platform-agnostic snapshot of a UI element captured from the accessibility tree.
/// Maps to the Rust `AccessibilityNode` type for cross-platform field matching.
struct CapturedElement {
    /// Opaque identifier (stringified AXUIElement hash).
    let id: String
    /// Accessibility role (e.g. "AXTextArea", "AXTextField").
    let role: String
    /// Accessibility label / title / description.
    let label: String
    /// Current text value.
    let value: String
    /// Position relative to screen.
    let position: CGPoint
    /// Element size.
    let size: CGSize
    /// Whether the element accepts text input.
    let isEditable: Bool
    /// The AXUIElement reference (for later interaction).
    let element: AXUIElement
}

/// Result of observing a user's click during teach mode.
struct TeachObservation {
    /// The captured element the user interacted with.
    let element: CapturedElement
    /// App name (e.g. "Google Chrome", "SimplePractice").
    let appName: String
    /// Window title (e.g. "Progress Note — Jane Smith").
    let windowTitle: String
    /// URL from the browser address bar, if applicable.
    let browserURL: String?
    /// All sibling text input elements in the same form/container.
    let siblingTextFields: [CapturedElement]
}

// MARK: - AccessibilityObserver

/// Observes user interactions with other apps via macOS Accessibility APIs.
/// Used during the "Teach Pablo" flow to capture which UI elements the therapist
/// clicks, so we can build a recipe for SOAP note entry.
@MainActor
final class AccessibilityObserver {

    // MARK: - Callbacks

    /// Called when the user clicks a text field in another app during teach mode.
    var onElementCaptured: ((TeachObservation) -> Void)?

    /// Called when observation mode starts/stops.
    var onObservingChanged: ((Bool) -> Void)?

    /// Called when there's an error (e.g. accessibility permission denied).
    var onError: ((String) -> Void)?

    // MARK: - State

    private(set) var isObserving = false
    private var globalMonitor: Any?
    private let logger = Logger(subsystem: "health.pablo.companion", category: "AccessibilityObserver")

    // MARK: - Permission Check

    /// Check whether the app has Accessibility permission.
    /// Returns true if granted, false otherwise.
    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompt the user to grant Accessibility permission (opens System Settings).
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Observation

    /// Start observing for user clicks on text fields in other apps.
    /// The observer uses a global event monitor to detect mouse clicks outside Pablo's window.
    func startObserving() {
        guard !isObserving else { return }
        guard Self.hasAccessibilityPermission() else {
            logger.warning("Accessibility permission not granted")
            onError?("Pablo needs Accessibility permission to learn where your notes go. Please grant it in System Settings > Privacy & Security > Accessibility.")
            Self.requestAccessibilityPermission()
            return
        }

        isObserving = true
        onObservingChanged?(true)
        logger.info("Teach mode: started observing")

        // Global event monitor for left mouse clicks outside our app
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            Task { @MainActor in
                self?.handleGlobalClick(at: event.locationInWindow, screenLocation: NSEvent.mouseLocation)
            }
        }
    }

    /// Stop observing.
    func stopObserving() {
        guard isObserving else { return }

        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }

        isObserving = false
        onObservingChanged?(false)
        logger.info("Teach mode: stopped observing")
    }

    // MARK: - Private

    private func handleGlobalClick(at windowPoint: NSPoint, screenLocation: NSPoint) {
        // Convert to screen coordinates (Cocoa uses bottom-left origin, AX uses top-left)
        guard let screen = NSScreen.main else { return }
        let axPoint = CGPoint(
            x: screenLocation.x,
            y: screen.frame.height - screenLocation.y
        )

        // Get the element at the click position
        let systemWide = AXUIElementCreateSystemWide()
        var elementRef: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(systemWide, Float(axPoint.x), Float(axPoint.y), &elementRef)

        guard result == .success, let element = elementRef else {
            logger.debug("No accessibility element at click position")
            return
        }

        // Check if this is a text input element
        guard let captured = captureElement(element), captured.isEditable else {
            logger.debug("Clicked element is not an editable text field — ignoring")
            return
        }

        // Get app and window info
        let appName = getAppName(for: element) ?? "Unknown App"
        let windowTitle = getWindowTitle(for: element) ?? ""
        let browserURL = getBrowserURL(for: element)

        // Find sibling text fields in the same container for field inference
        let siblings = findSiblingTextFields(near: element)

        let observation = TeachObservation(
            element: captured,
            appName: appName,
            windowTitle: windowTitle,
            browserURL: browserURL,
            siblingTextFields: siblings
        )

        logger.info("Teach mode: captured element '\(captured.label)' (role: \(captured.role)) in \(appName)")
        onElementCaptured?(observation)
    }

    /// Capture an AXUIElement into our platform-agnostic struct.
    private func captureElement(_ element: AXUIElement) -> CapturedElement? {
        let role = getStringAttribute(element, kAXRoleAttribute as String) ?? ""
        let label = getStringAttribute(element, kAXDescriptionAttribute as String)
            ?? getStringAttribute(element, kAXTitleAttribute as String)
            ?? ""
        let value = getStringAttribute(element, kAXValueAttribute as String) ?? ""

        var position = CGPoint.zero
        var size = CGSize.zero
        if let posValue = getAttribute(element, kAXPositionAttribute as String) {
            AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
        }
        if let sizeValue = getAttribute(element, kAXSizeAttribute as String) {
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        }

        let isEditable = isTextInputRole(role)

        return CapturedElement(
            id: "\(CFHash(element))",
            role: role,
            label: label,
            value: value,
            position: position,
            size: size,
            isEditable: isEditable,
            element: element
        )
    }

    /// Get the app name for the element's owning application.
    private func getAppName(for element: AXUIElement) -> String? {
        var app: AXUIElement?
        // Walk up to the application element
        var current = element
        while true {
            let role = getStringAttribute(current, kAXRoleAttribute as String)
            if role == kAXApplicationRole as String {
                app = current
                break
            }
            var parent: AnyObject?
            let result = AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent)
            guard result == .success, let parentElement = parent else { break }
            current = parentElement as! AXUIElement
        }
        if let app {
            return getStringAttribute(app, kAXTitleAttribute as String)
        }
        return nil
    }

    /// Get the window title for the element's owning window.
    private func getWindowTitle(for element: AXUIElement) -> String? {
        var current = element
        while true {
            let role = getStringAttribute(current, kAXRoleAttribute as String)
            if role == kAXWindowRole as String {
                return getStringAttribute(current, kAXTitleAttribute as String)
            }
            var parent: AnyObject?
            let result = AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent)
            guard result == .success, let parentElement = parent else { break }
            current = parentElement as! AXUIElement
        }
        return nil
    }

    /// Try to extract the URL from a browser address bar.
    /// Works with Safari, Chrome, Arc, Firefox, Edge.
    private func getBrowserURL(for element: AXUIElement) -> String? {
        // Walk up to the application
        var current = element
        while true {
            let role = getStringAttribute(current, kAXRoleAttribute as String)
            if role == kAXApplicationRole as String {
                break
            }
            var parent: AnyObject?
            let result = AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent)
            guard result == .success, let parentElement = parent else { return nil }
            current = parentElement as! AXUIElement
        }

        // For browsers, the focused window's document often has a URL attribute
        // Try AXDocument on the focused window
        var focusedWindow: AnyObject?
        let windowResult = AXUIElementCopyAttributeValue(
            current,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        )
        guard windowResult == .success, let window = focusedWindow else { return nil }

        // Chrome/Edge: AXDocument attribute on the window
        if let url = getStringAttribute(window as! AXUIElement, kAXDocumentAttribute as String) {
            return url
        }

        return nil
    }

    /// Find sibling text input fields in the same container as the given element.
    private func findSiblingTextFields(near element: AXUIElement) -> [CapturedElement] {
        // Get the parent container
        var parentRef: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef)
        guard result == .success, let parent = parentRef else { return [] }

        // Get all children of the parent
        var childrenRef: AnyObject?
        let childResult = AXUIElementCopyAttributeValue(
            parent as! AXUIElement,
            kAXChildrenAttribute as CFString,
            &childrenRef
        )
        guard childResult == .success, let children = childrenRef as? [AXUIElement] else { return [] }

        var textFields: [CapturedElement] = []
        for child in children {
            if let captured = captureElement(child), captured.isEditable {
                textFields.append(captured)
            }
            // Also check one level deeper (forms often wrap fields in containers)
            var grandchildrenRef: AnyObject?
            let gcResult = AXUIElementCopyAttributeValue(
                child,
                kAXChildrenAttribute as CFString,
                &grandchildrenRef
            )
            if gcResult == .success, let grandchildren = grandchildrenRef as? [AXUIElement] {
                for gc in grandchildren {
                    if let captured = captureElement(gc), captured.isEditable {
                        textFields.append(captured)
                    }
                }
            }
        }

        return textFields
    }

    // MARK: - AX Helpers

    private func getAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return result == .success ? value : nil
    }

    private func getStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        getAttribute(element, attribute) as? String
    }

    private func isTextInputRole(_ role: String) -> Bool {
        let textRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            "AXTextField",
            "AXTextArea",
            "AXComboBox",
            "AXSearchField",
        ]
        return textRoles.contains(role)
    }

    deinit {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
