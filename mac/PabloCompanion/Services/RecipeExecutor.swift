import ApplicationServices
import Cocoa
import Foundation
import os

// MARK: - Types

/// Result of attempting to fill a single SOAP field.
enum FieldFillResult {
    case success(section: String)
    case selectorNotFound(section: String)
    case setValueFailed(section: String, reason: String)
}

/// Result of executing a full recipe.
struct RecipeExecutionResult {
    let ehrDisplayName: String
    let fieldResults: [FieldFillResult]

    var allSucceeded: Bool {
        fieldResults.allSatisfy {
            if case .success = $0 { return true }
            return false
        }
    }

    var failedSections: [String] {
        fieldResults.compactMap {
            switch $0 {
            case .selectorNotFound(let section), .setValueFailed(let section, _):
                return section
            case .success:
                return nil
            }
        }
    }
}

/// The four SOAP note sections to fill.
struct SoapNoteContent {
    let subjective: String
    let objective: String
    let assessment: String
    let plan: String

    func content(for section: String) -> String? {
        switch section.lowercased() {
        case "subjective": return subjective
        case "objective": return objective
        case "assessment": return assessment
        case "plan": return plan
        default: return nil
        }
    }
}

// MARK: - RecipeExecutor

/// Tier 1: Deterministic replay of a saved recipe.
/// Resolves selectors via macOS Accessibility APIs and fills SOAP fields.
@MainActor
final class RecipeExecutor {

    // MARK: - Callbacks

    /// Progress update: which section is being filled.
    var onProgress: ((String) -> Void)?

    /// Called when execution completes.
    var onComplete: ((RecipeExecutionResult) -> Void)?

    // MARK: - Private

    private let logger = Logger(subsystem: "health.pablo.companion", category: "RecipeExecutor")

    // MARK: - Execution

    /// Execute a recipe: fill all SOAP fields in the foreground EHR window.
    ///
    /// - Parameters:
    ///   - recipe: The parsed recipe (from RecipeStore).
    ///   - soapNote: The SOAP note content to fill in.
    /// - Returns: Execution result with per-field outcomes.
    func execute(recipe: RecipeData, soapNote: SoapNoteContent) async -> RecipeExecutionResult {
        var fieldResults: [FieldFillResult] = []

        for field in recipe.fields {
            let section = field.soapSection
            onProgress?(section)
            logger.info("Filling \(section) field")

            guard let content = soapNote.content(for: section) else {
                logger.warning("No content for section \(section)")
                fieldResults.append(.setValueFailed(section: section, reason: "No content"))
                continue
            }

            // Execute navigation steps first (e.g. click a tab)
            for navStep in field.navigationSteps {
                await executeNavigationStep(navStep)
            }

            // Try to find the target element using selectors (priority order)
            if let element = resolveElement(selectors: field.selectors) {
                let result = fillElement(element, with: content, action: field.action)
                switch result {
                case true:
                    fieldResults.append(.success(section: section))
                    logger.info("Successfully filled \(section)")
                case false:
                    fieldResults.append(.setValueFailed(section: section, reason: "Could not set value"))
                    logger.warning("Failed to set value for \(section)")
                }
            } else {
                fieldResults.append(.selectorNotFound(section: section))
                logger.warning("Could not find element for \(section)")
            }

            // Small delay between fields to let the EHR UI settle
            try? await Task.sleep(for: .milliseconds(200))
        }

        let result = RecipeExecutionResult(
            ehrDisplayName: recipe.ehrDisplayName,
            fieldResults: fieldResults
        )
        onComplete?(result)
        return result
    }

    // MARK: - Element Resolution

    /// Try to find a UI element matching the given selectors.
    /// Resolution order: a11y_label + a11y_role first, then position as fallback.
    private func resolveElement(selectors: SelectorData) -> AXUIElement? {
        // Strategy 1: Find by accessibility label + role in the focused app
        if let label = selectors.a11yLabel {
            if let element = findElementByLabel(label, role: selectors.a11yRole) {
                logger.debug("Resolved by a11y label: '\(label)'")
                return element
            }
        }

        // Strategy 2: Position-based fallback
        if let position = selectors.position {
            let systemWide = AXUIElementCreateSystemWide()
            var elementRef: AXUIElement?
            let result = AXUIElementCopyElementAtPosition(
                systemWide,
                Float(position.x),
                Float(position.y),
                &elementRef
            )
            if result == .success, let element = elementRef {
                logger.debug("Resolved by position: (\(position.x), \(position.y))")
                return element
            }
        }

        return nil
    }

    /// Search the focused application's accessibility tree for an element matching
    /// the given label and optional role.
    private func findElementByLabel(_ label: String, role: String?) -> AXUIElement? {
        // Get the focused application
        guard let focusedApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(focusedApp.processIdentifier)

        // Get the focused window
        var windowRef: AnyObject?
        let windowResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowRef
        )
        guard windowResult == .success, let window = windowRef else { return nil }

        // Search the window's tree for matching elements
        return searchTree(
            root: window as! AXUIElement,
            label: label.lowercased(),
            role: role,
            maxDepth: 15
        )
    }

    /// Recursive depth-limited search of the accessibility tree.
    private func searchTree(root: AXUIElement, label: String, role: String?, maxDepth: Int) -> AXUIElement? {
        guard maxDepth > 0 else { return nil }

        // Check this element
        let elementLabel = (getStringAttribute(root, kAXDescriptionAttribute as String)
            ?? getStringAttribute(root, kAXTitleAttribute as String)
            ?? "").lowercased()

        if elementLabel.contains(label) {
            // If role is specified, also match it
            if let role {
                let elementRole = getStringAttribute(root, kAXRoleAttribute as String) ?? ""
                if elementRole == role {
                    return root
                }
            } else {
                return root
            }
        }

        // Search children
        var childrenRef: AnyObject?
        let result = AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &childrenRef)
        guard result == .success, let children = childrenRef as? [AXUIElement] else { return nil }

        for child in children {
            if let found = searchTree(root: child, label: label, role: role, maxDepth: maxDepth - 1) {
                return found
            }
        }

        return nil
    }

    // MARK: - Value Setting

    /// Fill an element with the given text content.
    private func fillElement(_ element: AXUIElement, with content: String, action: String) -> Bool {
        switch action {
        case "click_and_type":
            return clickAndType(element, content: content)
        default:
            // "set_value" — preferred path
            return setValue(element, content: content)
        }
    }

    /// Set value directly via AX API (preferred — fastest and most reliable).
    private func setValue(_ element: AXUIElement, content: String) -> Bool {
        // Focus the element first
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, true as CFTypeRef)

        // Set the value
        let result = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            content as CFTypeRef
        )
        return result == .success
    }

    /// Click the element, then paste content via clipboard (fallback for tricky controls).
    private func clickAndType(_ element: AXUIElement, content: String) -> Bool {
        // Get element position and click it
        var positionValue: AnyObject?
        let posResult = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
        guard posResult == .success, let posAXValue = positionValue else { return false }

        var position = CGPoint.zero
        AXValueGetValue(posAXValue as! AXValue, .cgPoint, &position)

        // Perform AX press action instead of simulating click (more reliable)
        AXUIElementPerformAction(element, kAXPressAction as CFString)

        // Small delay for focus to settle
        Thread.sleep(forTimeInterval: 0.1)

        // Select all existing content (Cmd+A) then paste
        let pasteboard = NSPasteboard.general
        let oldContents = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)

        // Cmd+A to select all in the field
        let selectAllDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x00, keyDown: true) // 'a'
        selectAllDown?.flags = .maskCommand
        selectAllDown?.post(tap: .cghidEventTap)
        let selectAllUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x00, keyDown: false)
        selectAllUp?.flags = .maskCommand
        selectAllUp?.post(tap: .cghidEventTap)

        Thread.sleep(forTimeInterval: 0.05)

        // Cmd+V to paste
        let pasteDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true) // 'v'
        pasteDown?.flags = .maskCommand
        pasteDown?.post(tap: .cghidEventTap)
        let pasteUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false)
        pasteUp?.flags = .maskCommand
        pasteUp?.post(tap: .cghidEventTap)

        // Restore old clipboard contents after a brief delay
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            if let old = oldContents {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(old, forType: .string)
            }
        }

        return true
    }

    // MARK: - Navigation Steps

    private func executeNavigationStep(_ step: NavigationStepData) async {
        if let element = resolveElement(selectors: step.selectors) {
            switch step.action {
            case "click":
                AXUIElementPerformAction(element, kAXPressAction as CFString)
            case "scroll":
                // Could implement scroll actions if needed
                break
            default:
                break
            }
        }
        if let delay = step.delayMs {
            try? await Task.sleep(for: .milliseconds(Int(delay)))
        }
    }

    // MARK: - AX Helpers

    private func getStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return result == .success ? value as? String : nil
    }
}

// MARK: - Recipe Data (parsed from JSON)

/// Swift representation of a recipe, parsed from the Rust-serialized JSON.
/// Kept separate from the Rust types to avoid UniFFI complexity for this module.
struct RecipeData: Codable {
    let schemaVersion: Int
    let ehrId: String
    let ehrDisplayName: String
    let urlPattern: String?
    let appIdentifier: String?
    let windowTitlePattern: String?
    let source: String
    let fields: [FieldMappingData]
    let lastVerified: String?
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case ehrId = "ehr_id"
        case ehrDisplayName = "ehr_display_name"
        case urlPattern = "url_pattern"
        case appIdentifier = "app_identifier"
        case windowTitlePattern = "window_title_pattern"
        case source, fields
        case lastVerified = "last_verified"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct FieldMappingData: Codable {
    let soapSection: String
    let selectors: SelectorData
    let action: String
    let navigationSteps: [NavigationStepData]

    enum CodingKeys: String, CodingKey {
        case soapSection = "soap_section"
        case selectors, action
        case navigationSteps = "navigation_steps"
    }
}

struct SelectorData: Codable {
    let a11yRole: String?
    let a11yLabel: String?
    let cssSelector: String?
    let xpath: String?
    let position: CGPoint?

    enum CodingKeys: String, CodingKey {
        case a11yRole = "a11y_role"
        case a11yLabel = "a11y_label"
        case cssSelector = "css_selector"
        case xpath
        case position
    }
}

struct NavigationStepData: Codable {
    let action: String
    let selectors: SelectorData
    let delayMs: UInt32?

    enum CodingKeys: String, CodingKey {
        case action, selectors
        case delayMs = "delay_ms"
    }
}
