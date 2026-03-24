import Foundation
import os

/// Orchestrates EHR browser automation via Chrome DevTools Protocol (CDP).
///
/// Connects to Chrome's remote debugging WebSocket (localhost:9222) to get
/// full DOM access — can find elements by CSS selector, click, fill forms,
/// and read page content. No macOS permissions required.
///
/// Flow:
///   1. Connect to Chrome CDP via WebSocket
///   2. Fetch cached route from backend (or discover via LLM)
///   3. For each step: get DOM snapshot → match fingerprint?
///      - YES → execute deterministically via CDP
///      - NO  → call backend `/navigate` (LLM fallback, PHI stripped)
///   4. Find patient by text search in DOM (deterministic, no LLM)
///   5. Pause at awaiting_confirmation → therapist reviews
///   6. On confirm → fill SOAP fields and save via CDP
@MainActor
final class EHRNavigator {
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "EHRNavigator")
    private let apiClient: NavigationAPIClient
    private var cdp: CDPConnection?

    init(apiClient: NavigationAPIClient) {
        self.apiClient = apiClient
    }

    // MARK: - Main orchestration

    /// The ordered intents that get us from EHR dashboard to SOAP entry form.
    /// When there's no cached route, the LLM works through these one at a time.
    private static let navigationIntents: [NavigationIntent] = [
        .findPatientList,
        .findPatientRow,
        .findSoapForm,
        .identifyFormFields,
    ]

    /// Runs the full SOAP entry flow. Returns confirmation data for the therapist to review.
    /// Does NOT save — caller must invoke `commitEntry()` after therapist confirms.
    func navigateToSoapForm(
        input: SoapEntryInput,
        onPhaseChange: @escaping (SoapEntryPhase, String) -> Void
    ) async throws -> SoapEntryConfirmation {
        // 1. Connect to Chrome CDP
        onPhaseChange(.navigating, "Connecting to browser...")
        let connection = try await connectToChrome()
        self.cdp = connection

        let dynamicData: [String: String] = [
            "patient_name": input.patientName,
            "appointment_time": input.appointmentTime,
        ]

        // 2. Try to fetch cached route (404 is fine — means we learn from scratch)
        onPhaseChange(.fetchingRoute, "Loading navigation route for \(input.ehrSystem)...")
        let cachedRoute = try? await apiClient.fetchRoute(ehrSystem: input.ehrSystem)

        // 3. Navigate — cached replay or full LLM discovery
        var learnedSteps: [CachedStep] = []
        onPhaseChange(.navigating, "Navigating \(input.ehrSystem)...")

        if let route = cachedRoute {
            logger.info("Using cached route for \(input.ehrSystem) (\(route.steps.count) steps)")
            learnedSteps = try await executeCachedRoute(
                route: route,
                dynamicData: dynamicData,
                input: input,
                cdp: connection,
                onPhaseChange: onPhaseChange
            )
        } else {
            logger.info("No cached route for \(input.ehrSystem) — learning via LLM")
            onPhaseChange(.navigating, "Learning \(input.ehrSystem) navigation (first time)...")
            learnedSteps = try await discoverRoute(
                input: input,
                cdp: connection,
                onPhaseChange: onPhaseChange
            )

            let newRoute = CachedRoute(
                ehrSystem: input.ehrSystem,
                routeName: "navigate_to_soap_entry",
                steps: learnedSteps,
                successCount: 1,
                lastSuccess: ISO8601DateFormatter().string(from: Date())
            )
            try? await apiClient.saveRoute(route: newRoute)
            logger.info("Saved learned route for \(input.ehrSystem) (\(learnedSteps.count) steps)")
        }

        // 4. Find and verify patient in the DOM
        onPhaseChange(.matchingPatient, "Looking for \(input.patientName)...")
        let pageText = try await connection.evaluateJS("document.body.innerText")
        let patientMatch = try findPatientMatch(in: pageText, name: input.patientName)
        let appointmentMatch = try findAppointmentMatch(in: pageText, time: input.appointmentTime)

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
        guard let cdp else {
            throw EHRNavigatorError.browserNotFound
        }

        onPhaseChange(.entering, "Entering SOAP note...")

        // Ask the LLM to identify the form fields on the current page
        let domSnapshot = try await getDOMSnapshot(cdp: cdp, patientName: input.patientName)
        let fieldAction = try await llmNavigate(
            intent: .identifyFormFields,
            ehrSystem: input.ehrSystem,
            domSnapshot: domSnapshot,
            patientName: input.patientName
        )

        // The LLM returns a selector pattern for the form fields.
        // We fill each SOAP section by evaluating JS directly.
        let soapFields = [
            ("Subjective", input.soapContent.subjective),
            ("Objective", input.soapContent.objective),
            ("Assessment", input.soapContent.assessment),
            ("Plan", input.soapContent.plan),
        ]

        for (label, content) in soapFields {
            onPhaseChange(.entering, "Filling \(label)...")
            // Use the LLM's selector as a base, fill via JS
            let escapedContent = content.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
            let fillJS = """
                (() => {
                    const fields = document.querySelectorAll('\(fieldAction.selector)');
                    for (const f of fields) {
                        if (f.labels?.[0]?.innerText?.includes('\(label)') ||
                            f.placeholder?.includes('\(label)') ||
                            f.getAttribute('aria-label')?.includes('\(label)')) {
                            f.value = '\(escapedContent)';
                            f.dispatchEvent(new Event('input', {bubbles: true}));
                            f.dispatchEvent(new Event('change', {bubbles: true}));
                            return true;
                        }
                    }
                    return false;
                })()
                """
            _ = try await cdp.evaluateJS(fillJS)
            try await Task.sleep(for: .milliseconds(300))
        }

        // Click save
        onPhaseChange(.entering, "Saving note...")
        let saveJS = """
            (() => {
                const btn = document.querySelector('button[type="submit"], input[type="submit"]')
                    || [...document.querySelectorAll('button')].find(b => /save|submit/i.test(b.innerText));
                if (btn) { btn.click(); return true; }
                return false;
            })()
            """
        _ = try await cdp.evaluateJS(saveJS)
    }

    // MARK: - Cached route execution

    private func executeCachedRoute(
        route: CachedRoute,
        dynamicData: [String: String],
        input: SoapEntryInput,
        cdp: CDPConnection,
        onPhaseChange: @escaping (SoapEntryPhase, String) -> Void
    ) async throws -> [CachedStep] {
        var updatedSteps = route.steps

        for (index, step) in route.steps.enumerated() {
            let domSnapshot = try await getDOMSnapshot(cdp: cdp, patientName: input.patientName)

            if matchesFingerprint(snapshot: domSnapshot, fingerprint: step.a11yFingerprint) {
                let resolvedSelector = resolveSelector(step.selector, dynamicKey: step.dynamicKey, data: dynamicData)
                try await executeStepViaCDP(action: step.action, selector: resolvedSelector, cdp: cdp)
                logger.info("Step \(index + 1)/\(route.steps.count) matched — deterministic")
            } else {
                logger.info("Step \(index + 1)/\(route.steps.count) mismatch — calling LLM")
                onPhaseChange(.navigating, "Step \(index + 1) changed — asking AI...")
                let action = try await llmNavigate(
                    intent: step.intent,
                    ehrSystem: input.ehrSystem,
                    domSnapshot: domSnapshot,
                    patientName: input.patientName,
                    failedSelector: step.selector
                )
                try await executeStepViaCDP(action: action.action, selector: action.selector, cdp: cdp)

                updatedSteps[index] = CachedStep(
                    action: action.action,
                    selector: action.selector,
                    a11yFingerprint: action.updatedFingerprint.isEmpty ? step.a11yFingerprint : action.updatedFingerprint,
                    intent: step.intent,
                    dynamicKey: step.dynamicKey
                )

                if !action.updatedFingerprint.isEmpty {
                    try? await apiClient.reportRouteUpdate(
                        ehrSystem: input.ehrSystem,
                        stepIndex: index,
                        newSelector: action.selector,
                        newFingerprint: action.updatedFingerprint
                    )
                }
            }

            // Wait for page to settle after action
            try await Task.sleep(for: .milliseconds(800))
        }

        return updatedSteps
    }

    // MARK: - LLM-driven route discovery

    private func discoverRoute(
        input: SoapEntryInput,
        cdp: CDPConnection,
        onPhaseChange: @escaping (SoapEntryPhase, String) -> Void
    ) async throws -> [CachedStep] {
        var learnedSteps: [CachedStep] = []

        for (index, intent) in Self.navigationIntents.enumerated() {
            let domSnapshot = try await getDOMSnapshot(cdp: cdp, patientName: input.patientName)
            onPhaseChange(.navigating, "Step \(index + 1)/\(Self.navigationIntents.count): \(intent.rawValue.replacingOccurrences(of: "_", with: " "))...")

            let action = try await llmNavigate(
                intent: intent,
                ehrSystem: input.ehrSystem,
                domSnapshot: domSnapshot,
                patientName: input.patientName
            )

            try await executeStepViaCDP(action: action.action, selector: action.selector, cdp: cdp)

            let dynamicKey: String? = switch intent {
            case .findPatientRow: "patient_name"
            default: nil
            }

            learnedSteps.append(CachedStep(
                action: action.action,
                selector: action.selector,
                a11yFingerprint: action.updatedFingerprint,
                intent: intent,
                dynamicKey: dynamicKey
            ))

            logger.info("Learned step \(index + 1): \(intent.rawValue) → \(action.action.rawValue) on \(action.selector)")
            try await Task.sleep(for: .milliseconds(800))
        }

        return learnedSteps
    }

    // MARK: - CDP actions

    /// Executes a navigation action via CDP (click, fill, navigate, wait).
    private func executeStepViaCDP(action: StepAction, selector: String, cdp: CDPConnection) async throws {
        logger.info("CDP: \(action.rawValue) on \(selector)")

        switch action {
        case .click:
            let js = """
                (() => {
                    const el = document.querySelector('\(selector.escapedForJS)');
                    if (el) { el.click(); return true; }
                    return false;
                })()
                """
            let result = try await cdp.evaluateJS(js)
            if result == "false" {
                throw EHRNavigatorError.elementNotFound(selector: selector)
            }

        case .fill:
            // Fill is handled separately in commitEntry with field-specific logic
            break

        case .navigate:
            _ = try await cdp.evaluateJS("window.location.href = '\(selector.escapedForJS)'")

        case .wait:
            try await Task.sleep(for: .seconds(1))
        }
    }

    /// Gets a simplified DOM snapshot for the LLM. Strips PHI before returning.
    private func getDOMSnapshot(cdp: CDPConnection, patientName: String) async throws -> String {
        // Get a simplified representation of the page — interactive elements + text
        let js = """
            (() => {
                const elements = [];
                const walk = (el, depth) => {
                    if (depth > 6) return;
                    const tag = el.tagName?.toLowerCase() || '';
                    const role = el.getAttribute?.('role') || '';
                    const text = el.innerText?.substring(0, 100) || '';
                    const href = el.getAttribute?.('href') || '';
                    const type = el.getAttribute?.('type') || '';
                    const placeholder = el.getAttribute?.('placeholder') || '';
                    const ariaLabel = el.getAttribute?.('aria-label') || '';
                    const isInteractive = ['A','BUTTON','INPUT','SELECT','TEXTAREA'].includes(el.tagName)
                        || el.getAttribute?.('onclick')
                        || role === 'button' || role === 'link' || role === 'tab';
                    if (isInteractive || text.length > 0) {
                        const indent = '  '.repeat(depth);
                        let desc = `${indent}<${tag}`;
                        if (role) desc += ` role="${role}"`;
                        if (href) desc += ` href="${href}"`;
                        if (type) desc += ` type="${type}"`;
                        if (placeholder) desc += ` placeholder="${placeholder}"`;
                        if (ariaLabel) desc += ` aria-label="${ariaLabel}"`;
                        desc += `>${text.substring(0, 80).replace(/\\n/g, ' ')}`;
                        elements.push(desc);
                    }
                    for (const child of (el.children || [])) walk(child, depth + 1);
                };
                walk(document.body, 0);
                return elements.join('\\n');
            })()
            """
        let rawSnapshot = try await cdp.evaluateJS(js)
        return stripPHI(from: rawSnapshot, patientName: patientName)
    }

    // MARK: - CDP connection

    /// Connects to Chrome's remote debugging port and finds the active page target.
    private func connectToChrome(port: Int = 9222) async throws -> CDPConnection {
        // Step 1: Get the list of debuggable targets
        guard let listURL = URL(string: "http://localhost:\(port)/json") else {
            throw EHRNavigatorError.browserNotFound
        }

        let (data, _) = try await URLSession.shared.data(from: listURL)

        guard let targets = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw EHRNavigatorError.browserNotFound
        }

        // Find the first "page" target (not extension, service worker, etc.)
        guard let pageTarget = targets.first(where: { ($0["type"] as? String) == "page" }),
              let wsURL = pageTarget["webSocketDebuggerUrl"] as? String else {
            throw EHRNavigatorError.browserNotFound
        }

        logger.info("CDP: Connecting to \(wsURL)")

        // Step 2: Connect WebSocket
        let connection = CDPConnection(wsURL: wsURL)
        try await connection.connect()

        logger.info("CDP: Connected to Chrome")
        return connection
    }

    // MARK: - LLM call

    private func llmNavigate(
        intent: NavigationIntent,
        ehrSystem: String,
        domSnapshot: String,
        patientName: String,
        failedSelector: String = ""
    ) async throws -> NavigationAction {
        let strippedSnapshot = stripPHI(from: domSnapshot, patientName: patientName)
        return try await apiClient.getNavigationAction(
            request: NavigationRequest(
                ehrSystem: ehrSystem,
                intent: intent,
                a11ySnapshot: strippedSnapshot,
                failedSelector: failedSelector
            )
        )
    }

    // MARK: - Matching

    private func matchesFingerprint(snapshot: String, fingerprint: String) -> Bool {
        guard !fingerprint.isEmpty else { return false }
        return snapshot.contains(fingerprint)
    }

    private func findPatientMatch(in pageText: String, name: String) throws -> String {
        if pageText.localizedCaseInsensitiveContains(name) {
            return name
        }
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            let reversed = "\(parts.last!), \(parts.first!)"
            if pageText.localizedCaseInsensitiveContains(reversed) {
                return String(reversed)
            }
        }
        throw EHRNavigatorError.patientNotFound(name: name)
    }

    private func findAppointmentMatch(in pageText: String, time: String) throws -> String {
        if pageText.contains(time) { return time }
        if let date = ISO8601DateFormatter().date(from: time) {
            let formatter = DateFormatter()
            for format in ["h:mm a", "HH:mm", "h:mma", "h:mm\u{202F}a", "h:mm\u{00A0}a"] {
                formatter.dateFormat = format
                let formatted = formatter.string(from: date)
                if pageText.localizedCaseInsensitiveContains(formatted) {
                    return formatted
                }
            }
        }
        throw EHRNavigatorError.appointmentNotFound(time: time)
    }

    // MARK: - Helpers

    private func resolveSelector(_ selector: String, dynamicKey: String?, data: [String: String]) -> String {
        guard let key = dynamicKey, let value = data[key] else { return selector }
        return selector.replacingOccurrences(of: "{\(key)}", with: value)
    }

    private func stripPHI(from text: String, patientName: String) -> String {
        var stripped = text.replacingOccurrences(of: patientName, with: "[PATIENT]")
        for part in patientName.split(separator: " ") where part.count > 2 {
            stripped = stripped.replacingOccurrences(of: String(part), with: "[NAME]")
        }
        return stripped
    }
}

// MARK: - CDP WebSocket Connection

/// Minimal Chrome DevTools Protocol client over WebSocket.
/// Sends JSON commands and receives responses by matching request IDs.
final class CDPConnection: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let wsURL: String
    private var webSocket: URLSessionWebSocketTask?
    private var nextID = 1
    private var pendingCallbacks: [Int: CheckedContinuation<String, Error>] = [:]
    private let lock = NSLock()
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "CDPConnection")

    init(wsURL: String) {
        self.wsURL = wsURL
    }

    func connect() async throws {
        guard let url = URL(string: wsURL) else {
            throw EHRNavigatorError.browserNotFound
        }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let ws = session.webSocketTask(with: url)
        self.webSocket = ws
        ws.resume()
        startReceiving()
        // Give the connection a moment to establish
        try await Task.sleep(for: .milliseconds(200))
    }

    /// Evaluates JavaScript in the page and returns the string result.
    func evaluateJS(_ expression: String) async throws -> String {
        let id = nextRequestID()
        let command: [String: Any] = [
            "id": id,
            "method": "Runtime.evaluate",
            "params": [
                "expression": expression,
                "returnByValue": true,
            ],
        ]
        return try await sendCommand(command, id: id)
    }

    // MARK: - Internal

    private func nextRequestID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        return id
    }

    private func sendCommand(_ command: [String: Any], id: Int) async throws -> String {
        guard let ws = webSocket else {
            throw EHRNavigatorError.browserNotFound
        }

        let data = try JSONSerialization.data(withJSONObject: command)
        let message = URLSessionWebSocketTask.Message.data(data)

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pendingCallbacks[id] = continuation
            lock.unlock()

            ws.send(message) { [weak self] error in
                if let error {
                    self?.lock.lock()
                    let cb = self?.pendingCallbacks.removeValue(forKey: id)
                    self?.lock.unlock()
                    cb?.resume(throwing: error)
                }
            }
        }
    }

    private func startReceiving() {
        webSocket?.receive { [weak self] result in
            switch result {
            case let .success(message):
                self?.handleMessage(message)
                self?.startReceiving() // Continue listening
            case let .failure(error):
                self?.logger.error("CDP WebSocket error: \(error.localizedDescription)")
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case let .string(text):
            data = Data(text.utf8)
        case let .data(d):
            data = d
        @unknown default:
            return
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? Int else {
            return // Event message (no id) — ignore for now
        }

        lock.lock()
        let continuation = pendingCallbacks.removeValue(forKey: id)
        lock.unlock()

        // Extract the result value
        if let result = json["result"] as? [String: Any],
           let innerResult = result["result"] as? [String: Any],
           let value = innerResult["value"] {
            if let strValue = value as? String {
                continuation?.resume(returning: strValue)
            } else if let boolValue = value as? Bool {
                continuation?.resume(returning: boolValue ? "true" : "false")
            } else {
                continuation?.resume(returning: String(describing: value))
            }
        } else if let error = json["error"] as? [String: Any],
                  let errorMessage = error["message"] as? String {
            continuation?.resume(throwing: EHRNavigatorError.actionFailed(action: "CDP", selector: errorMessage))
        } else {
            continuation?.resume(returning: "")
        }
    }
}

// MARK: - String helper

private extension String {
    /// Escapes a string for safe inclusion in a JS string literal (single-quoted).
    var escapedForJS: String {
        self.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

// MARK: - Errors

enum EHRNavigatorError: LocalizedError {
    case browserNotFound
    case patientNotFound(name: String)
    case appointmentNotFound(time: String)
    case elementNotFound(selector: String)
    case actionFailed(action: String, selector: String)
    case routeNotAvailable(ehrSystem: String)

    var errorDescription: String? {
        switch self {
        case .browserNotFound:
            "Could not connect to Chrome. Make sure Chrome is running with --remote-debugging-port=9222"
        case let .patientNotFound(name):
            "Could not find patient \"\(name)\" on the current page."
        case let .appointmentNotFound(time):
            "Could not find appointment at \(time) on the current page."
        case let .elementNotFound(selector):
            "Could not find element: \(selector)"
        case let .actionFailed(action, selector):
            "Failed to \(action): \(selector)"
        case let .routeNotAvailable(ehrSystem):
            "No navigation route available for \(ehrSystem)."
        }
    }
}
