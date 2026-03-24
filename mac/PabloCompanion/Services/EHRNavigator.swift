import AppKit
import ApplicationServices
import Foundation
import os

/// Orchestrates EHR browser automation using macOS Accessibility APIs.
///
/// The navigator controls the therapist's browser (Safari, Chrome, etc.)
/// via AXUIElement to enter SOAP notes into their EHR. All intelligence
/// stays local except when the DOM doesn't match a cached route — then
/// it calls the backend for LLM-assisted navigation.
///
/// Flow:
///   1. Fetch cached route for this EHR system from backend
///   2. For each step: read accessibility tree → match fingerprint?
///      - YES → execute deterministically
///      - NO  → call backend `/navigate` (LLM fallback, PHI stripped)
///   3. Find patient by text search (deterministic, no LLM)
///   4. Pause at awaiting_confirmation → therapist reviews
///   5. On confirm → fill SOAP fields and save
@MainActor
final class EHRNavigator {
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "EHRNavigator")
    private let apiClient: NavigationAPIClient

    init(apiClient: NavigationAPIClient) {
        self.apiClient = apiClient
    }

    // MARK: - Main orchestration

    /// Runs the full SOAP entry flow. Returns confirmation data for the therapist to review.
    /// Does NOT save — caller must invoke `commitEntry()` after therapist confirms.
    func navigateToSoapForm(
        input: SoapEntryInput,
        onPhaseChange: @escaping (SoapEntryPhase, String) -> Void
    ) async throws -> SoapEntryConfirmation {
        // 1. Fetch cached route
        onPhaseChange(.fetchingRoute, "Loading navigation route for \(input.ehrSystem)...")
        let route = try await apiClient.fetchRoute(ehrSystem: input.ehrSystem)

        // 2. Find the browser window
        guard let browserWindow = findBrowserWindow() else {
            throw EHRNavigatorError.browserNotFound
        }

        // 3. Execute cached steps
        onPhaseChange(.navigating, "Navigating \(input.ehrSystem)...")
        let dynamicData: [String: String] = [
            "patient_name": input.patientName,
            "appointment_time": input.appointmentTime,
        ]

        for (index, step) in route.steps.enumerated() {
            let tree = try accessibilitySnapshot(for: browserWindow)

            if matchesFingerprint(tree: tree, fingerprint: step.a11yFingerprint) {
                // Deterministic execution
                let resolvedSelector = resolveSelector(step.selector, dynamicKey: step.dynamicKey, data: dynamicData)
                try await executeAction(step.action, selector: resolvedSelector, on: browserWindow)
                logger.info("Step \(index + 1)/\(route.steps.count) matched — executed deterministically")
            } else {
                // LLM fallback — strip PHI before sending
                logger.info("Step \(index + 1)/\(route.steps.count) did not match — calling backend LLM")
                let strippedTree = stripPHI(from: tree, patientName: input.patientName)
                let action = try await apiClient.getNavigationAction(
                    request: NavigationRequest(
                        ehrSystem: input.ehrSystem,
                        intent: step.intent,
                        a11ySnapshot: strippedTree,
                        failedSelector: step.selector
                    )
                )
                try await executeAction(action.action, selector: action.selector, on: browserWindow)

                // Report the updated step so the route improves for everyone
                if let updatedFingerprint = action.updatedFingerprint {
                    try? await apiClient.reportRouteUpdate(
                        ehrSystem: input.ehrSystem,
                        stepIndex: index,
                        newSelector: action.selector,
                        newFingerprint: updatedFingerprint
                    )
                }
            }

            // Brief pause between actions — mimics human timing, avoids rate limiting
            try await Task.sleep(for: .milliseconds(500))
        }

        // 4. Find and verify patient
        onPhaseChange(.matchingPatient, "Looking for \(input.patientName)...")
        let tree = try accessibilitySnapshot(for: browserWindow)
        let patientMatch = try findPatientMatch(in: tree, name: input.patientName)
        let appointmentMatch = try findAppointmentMatch(in: tree, time: input.appointmentTime)

        // 5. Return confirmation for therapist review
        return SoapEntryConfirmation(
            patientMatch: patientMatch,
            appointmentMatch: appointmentMatch,
            ehrTargetField: "\(input.ehrSystem) → Patient Notes → SOAP Note",
            soapPreview: "S: \(input.soapContent.subjective.prefix(80))..."
        )
    }

    /// After therapist confirms, fill the SOAP fields and click Save.
    func commitEntry(
        input: SoapEntryInput,
        onPhaseChange: @escaping (SoapEntryPhase, String) -> Void
    ) async throws {
        guard let browserWindow = findBrowserWindow() else {
            throw EHRNavigatorError.browserNotFound
        }

        onPhaseChange(.entering, "Entering SOAP note...")

        // Fill each SOAP field using cached field selectors
        let fields: [(NavigationIntent, String)] = [
            (.findSoapForm, input.soapContent.subjective),
            (.findSoapForm, input.soapContent.objective),
            (.findSoapForm, input.soapContent.assessment),
            (.findSoapForm, input.soapContent.plan),
        ]

        for (_, content) in fields {
            // The actual field identification logic would use cached selectors
            // or LLM fallback to find S/O/A/P fields in the EHR form
            try await typeText(content, into: browserWindow)
            try await Task.sleep(for: .milliseconds(300))
        }

        // Click save
        onPhaseChange(.entering, "Saving note...")
        try await executeAction(.click, selector: "button[type='submit'], button:contains('Save')", on: browserWindow)
    }

    // MARK: - Accessibility tree

    /// Reads the accessibility tree of the browser window as a text snapshot.
    private func accessibilitySnapshot(for window: AXUIElement) throws -> String {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &value)
        guard result == .success, let children = value as? [AXUIElement] else {
            throw EHRNavigatorError.accessibilityTreeUnavailable
        }
        return serializeAccessibilityTree(children, depth: 0, maxDepth: 10)
    }

    /// Recursively serializes the accessibility tree to a text representation.
    private func serializeAccessibilityTree(_ elements: [AXUIElement], depth: Int, maxDepth: Int) -> String {
        guard depth < maxDepth else { return "" }
        var result = ""
        let indent = String(repeating: "  ", count: depth)

        for element in elements {
            let role = axAttribute(element, kAXRoleAttribute) ?? "unknown"
            let title = axAttribute(element, kAXTitleAttribute) ?? ""
            let value = axAttribute(element, kAXValueAttribute) ?? ""
            let desc = axAttribute(element, kAXDescriptionAttribute) ?? ""

            let label = [title, value, desc].filter { !$0.isEmpty }.joined(separator: " | ")
            result += "\(indent)[\(role)] \(label)\n"

            // Recurse into children
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                result += serializeAccessibilityTree(children, depth: depth + 1, maxDepth: maxDepth)
            }
        }
        return result
    }

    /// Reads a single string attribute from an AXUIElement.
    private func axAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    // MARK: - Browser discovery

    /// Finds the frontmost browser window (Safari, Chrome, Firefox, Arc, Edge).
    private func findBrowserWindow() -> AXUIElement? {
        let browserBundleIDs = [
            "com.apple.Safari",
            "com.google.Chrome",
            "org.mozilla.firefox",
            "company.thebrowser.Browser", // Arc
            "com.microsoft.edgemac",
        ]

        for app in NSWorkspace.shared.runningApplications where app.isActive {
            if let bundleID = app.bundleIdentifier, browserBundleIDs.contains(bundleID) {
                let appElement = AXUIElementCreateApplication(app.processIdentifier)
                var windowRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success {
                    // swiftlint:disable:next force_cast
                    return (windowRef as! AXUIElement)
                }
            }
        }

        // Fallback: check all running browsers, not just the active one
        for app in NSWorkspace.shared.runningApplications {
            if let bundleID = app.bundleIdentifier, browserBundleIDs.contains(bundleID) {
                let appElement = AXUIElementCreateApplication(app.processIdentifier)
                var windowRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success {
                    // swiftlint:disable:next force_cast
                    return (windowRef as! AXUIElement)
                }
            }
        }

        return nil
    }

    // MARK: - Matching

    /// Checks if the current accessibility tree matches a cached step's fingerprint.
    private func matchesFingerprint(tree: String, fingerprint: String) -> Bool {
        // Exact substring match on key structural elements.
        // The fingerprint is a hash or snippet of the expected tree structure
        // (excluding dynamic content like patient names or times).
        tree.contains(fingerprint)
    }

    /// Deterministic text search for the patient name in the accessibility tree.
    /// No LLM needed — pure string matching.
    private func findPatientMatch(in tree: String, name: String) throws -> String {
        // Try exact match first
        if tree.localizedCaseInsensitiveContains(name) {
            return name
        }

        // Try last name, first name format
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            let reversed = "\(parts.last!), \(parts.first!)"
            if tree.localizedCaseInsensitiveContains(reversed) {
                return String(reversed)
            }
        }

        throw EHRNavigatorError.patientNotFound(name: name)
    }

    /// Deterministic text search for the appointment time.
    private func findAppointmentMatch(in tree: String, time: String) throws -> String {
        // Try the ISO time directly
        if tree.contains(time) {
            return time
        }

        // Try common display formats (2:00 PM, 14:00, etc.)
        if let date = ISO8601DateFormatter().date(from: time) {
            let formatter = DateFormatter()
            for format in ["h:mm a", "HH:mm", "h:mma"] {
                formatter.dateFormat = format
                let formatted = formatter.string(from: date)
                if tree.localizedCaseInsensitiveContains(formatted) {
                    return formatted
                }
            }
        }

        throw EHRNavigatorError.appointmentNotFound(time: time)
    }

    // MARK: - PHI stripping

    /// Removes patient-identifiable information before sending to the backend LLM.
    private func stripPHI(from tree: String, patientName: String) -> String {
        var stripped = tree.replacingOccurrences(of: patientName, with: "[PATIENT]")

        // Also strip individual name parts (handles "Smith, Jane" formats)
        for part in patientName.split(separator: " ") where part.count > 2 {
            stripped = stripped.replacingOccurrences(of: String(part), with: "[NAME]")
        }

        return stripped
    }

    // MARK: - Action execution

    /// Resolves a selector with dynamic data substitution.
    private func resolveSelector(_ selector: String, dynamicKey: String?, data: [String: String]) -> String {
        guard let key = dynamicKey, let value = data[key] else {
            return selector
        }
        return selector.replacingOccurrences(of: "{\(key)}", with: value)
    }

    /// Executes a browser action via Accessibility APIs.
    private func executeAction(_ action: StepAction, selector: String, on window: AXUIElement) async throws {
        // In a full implementation, this would:
        // 1. Walk the accessibility tree to find the element matching `selector`
        // 2. Perform the action (click via AXPress, fill via AXValue, etc.)
        //
        // For now, this is the integration point. The selector format and
        // tree-walking logic will be refined per EHR system during testing.
        logger.info("Executing \(action.rawValue) on selector: \(selector)")

        switch action {
        case .click:
            try pressElement(matching: selector, in: window)
        case .fill:
            // Fill is handled by typeText — selector identifies the field
            break
        case .navigate:
            // URL navigation — would set the browser's URL bar
            break
        case .wait:
            try await Task.sleep(for: .seconds(1))
        }
    }

    /// Presses (clicks) an element found by walking the accessibility tree.
    private func pressElement(matching selector: String, in root: AXUIElement) throws {
        guard let element = findElement(matching: selector, in: root) else {
            throw EHRNavigatorError.elementNotFound(selector: selector)
        }
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success else {
            throw EHRNavigatorError.actionFailed(action: "press", selector: selector)
        }
    }

    /// Walks the accessibility tree to find an element matching a selector.
    private func findElement(matching selector: String, in root: AXUIElement) -> AXUIElement? {
        // Simple text-based matching against title/description/role
        let title = axAttribute(root, kAXTitleAttribute) ?? ""
        let desc = axAttribute(root, kAXDescriptionAttribute) ?? ""
        let role = axAttribute(root, kAXRoleAttribute) ?? ""

        if title.localizedCaseInsensitiveContains(selector)
            || desc.localizedCaseInsensitiveContains(selector)
            || "\(role):\(title)".localizedCaseInsensitiveContains(selector) {
            return root
        }

        // Recurse into children
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                if let found = findElement(matching: selector, in: child) {
                    return found
                }
            }
        }

        return nil
    }

    /// Types text into the currently focused element.
    private func typeText(_ text: String, into window: AXUIElement) async throws {
        // Use AXValue to set text on the focused element
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success else {
            throw EHRNavigatorError.accessibilityTreeUnavailable
        }
        // swiftlint:disable:next force_cast
        let focused = focusedRef as! AXUIElement
        let result = AXUIElementSetAttributeValue(focused, kAXValueAttribute as CFString, text as CFTypeRef)
        guard result == .success else {
            throw EHRNavigatorError.actionFailed(action: "type", selector: "focused element")
        }
    }
}

// MARK: - Errors

enum EHRNavigatorError: LocalizedError {
    case browserNotFound
    case accessibilityTreeUnavailable
    case patientNotFound(name: String)
    case appointmentNotFound(time: String)
    case elementNotFound(selector: String)
    case actionFailed(action: String, selector: String)
    case routeNotAvailable(ehrSystem: String)

    var errorDescription: String? {
        switch self {
        case .browserNotFound:
            "No supported browser found. Please open your EHR in Safari, Chrome, or Firefox."
        case .accessibilityTreeUnavailable:
            "Unable to read browser content. Please grant Accessibility permission in System Settings."
        case let .patientNotFound(name):
            "Could not find patient \"\(name)\" in the current page."
        case let .appointmentNotFound(time):
            "Could not find appointment at \(time) in the current page."
        case let .elementNotFound(selector):
            "Could not find element: \(selector)"
        case let .actionFailed(action, selector):
            "Failed to \(action) on \(selector)"
        case let .routeNotAvailable(ehrSystem):
            "No navigation route available for \(ehrSystem). Please contact support."
        }
    }
}
