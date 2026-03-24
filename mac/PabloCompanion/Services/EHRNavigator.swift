import AppKit
import Foundation
import os

/// Orchestrates EHR browser automation via Chrome DevTools Protocol (CDP).
///
/// Uses a goal-based navigation loop: sends the current page DOM + goal to
/// the backend LLM, executes the returned action, and repeats until the LLM
/// says we're on the target page. PHI is stripped before every LLM call.
@MainActor
final class EHRNavigator {
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "EHRNavigator")
    private let apiClient: NavigationAPIClient
    private var cdp: CDPConnection?

    /// Called when Chrome needs to be relaunched with debugging enabled.
    /// The UI should show a confirmation dialog. Return `true` to proceed.
    var onChromeRelaunchNeeded: (() async -> Bool)?

    /// Maximum navigation steps before giving up (safety limit).
    private let maxSteps = 10

    init(apiClient: NavigationAPIClient) {
        self.apiClient = apiClient
    }

    // MARK: - EHR login URLs

    private static let ehrLoginURLs: [String: String] = [
        "simplepractice": "https://secure.simplepractice.com",
        "therapynotes": "https://www.therapynotes.com/Account/Login",
        "janeapp": "https://jane.app/login",
        "sessions_health": "https://app.sessionshealth.com",
    ]

    // MARK: - Main orchestration

    /// Navigates to the SOAP note form using a goal-based LLM loop.
    ///
    /// 1. Connect to Chrome via CDP
    /// 2. Send current page DOM + goal to backend LLM
    /// 3. Execute the returned action (click, navigate, wait)
    /// 4. Repeat until LLM says we're on the target page
    /// 5. Verify patient + time via local text match (no LLM)
    /// 6. Return confirmation for therapist review
    func navigateToSoapForm(
        input: SoapEntryInput,
        onPhaseChange: @escaping (SoapEntryPhase, String) -> Void
    ) async throws -> SoapEntryConfirmation {
        // 1. Connect to Chrome
        onPhaseChange(.connecting, "Connecting to browser...")
        let connection = try await connectToChrome(ehrSystem: input.ehrSystem)
        self.cdp = connection

        // 2. Goal-based navigation loop
        let goal = "Navigate to the SOAP note form for the appointment at \(input.appointmentDisplay)"
        var previousActions: [PreviousAction] = []
        var formFields: SoapFormFields?

        onPhaseChange(.navigating, "Looking for the appointment...")

        for step in 1 ... maxSteps {
            let currentURL = try await connection.evaluateJS("window.location.href")
            let domSnapshot = try await getDOMSnapshot(cdp: connection, patientName: input.patientName)

            // Ask the LLM what to do next
            let response = try await apiClient.navigate(
                request: GoalNavigationRequest(
                    ehrSystem: input.ehrSystem,
                    goal: goal,
                    currentUrl: currentURL,
                    domSnapshot: domSnapshot,
                    previousActions: previousActions,
                    failedAction: nil
                )
            )

            logger.info("Step \(step): \(response.action.rawValue) → \(response.selector) (\(response.reasoning))")
            onPhaseChange(.navigating, "Step \(step): \(response.reasoning)")

            // Are we on the target page?
            if response.isOnTargetPage {
                formFields = response.formFields
                logger.info("On target page after \(step) step(s)")
                break
            }

            // Execute the action
            do {
                try await executeAction(response.action, selector: response.selector, cdp: connection)
                previousActions.append(PreviousAction(
                    action: response.action.rawValue,
                    target: response.selector,
                    result: "success"
                ))
            } catch {
                logger.warning("Step \(step) failed: \(error.localizedDescription)")
                previousActions.append(PreviousAction(
                    action: response.action.rawValue,
                    target: response.selector,
                    result: "failed: \(error.localizedDescription)"
                ))
                // Don't throw — let the LLM see the failure and try an alternative
            }

            // Wait for page to settle
            try await Task.sleep(for: .milliseconds(800))
        }

        // 3. Verify patient + time via local text match (no LLM)
        onPhaseChange(.matchingPatient, "Verifying patient...")
        let pageText = try await connection.evaluateJS("document.body.innerText")
        let patientMatch = try findPatientMatch(in: pageText, name: input.patientName)
        let appointmentMatch = try findAppointmentMatch(in: pageText, time: input.appointmentTime)

        return SoapEntryConfirmation(
            patientMatch: patientMatch,
            appointmentMatch: appointmentMatch,
            ehrTargetField: "\(input.ehrSystem) → SOAP Note",
            soapPreview: "S: \(input.soapContent.subjective.prefix(80))...",
            formFields: formFields
        )
    }

    /// After therapist confirms, fill the SOAP fields and leave for them to review/submit.
    func commitEntry(
        input: SoapEntryInput,
        formFields: SoapFormFields?,
        onPhaseChange: @escaping (SoapEntryPhase, String) -> Void
    ) async throws {
        guard let cdp else {
            throw EHRNavigatorError.browserNotFound
        }

        onPhaseChange(.entering, "Entering SOAP note...")

        // Use LLM-identified selectors if available, otherwise fall back to position-based
        let fields = formFields ?? SoapFormFields(
            subjective: "textarea.expanding-textarea:nth-of-type(1)",
            objective: "textarea.expanding-textarea:nth-of-type(2)",
            assessment: "textarea.expanding-textarea:nth-of-type(3)",
            plan: "textarea.expanding-textarea:nth-of-type(4)"
        )

        let soapEntries: [(String, String, String)] = [
            ("Subjective", fields.subjective, input.soapContent.subjective),
            ("Objective", fields.objective, input.soapContent.objective),
            ("Assessment", fields.assessment, input.soapContent.assessment),
            ("Plan", fields.plan, input.soapContent.plan),
        ]

        for (label, selector, content) in soapEntries {
            onPhaseChange(.entering, "Filling \(label)...")
            let escaped = content.escapedForJS
            let js = """
                (() => {
                    // Try the LLM selector first
                    let el = document.querySelector('\(selector.escapedForJS)');
                    // Fallback: find by position among expanding textareas
                    if (!el) {
                        const all = document.querySelectorAll('textarea.expanding-textarea');
                        const idx = {'Subjective':0,'Objective':1,'Assessment':2,'Plan':3}['\(label)'];
                        el = all[idx];
                    }
                    if (!el) return 'NOT_FOUND';
                    el.focus();
                    el.value = '\(escaped)';
                    el.dispatchEvent(new Event('input', {bubbles: true}));
                    el.dispatchEvent(new Event('change', {bubbles: true}));
                    return 'filled';
                })()
                """
            let result = try await cdp.evaluateJS(js)
            if result == "NOT_FOUND" {
                throw EHRNavigatorError.elementNotFound(selector: "\(label) field")
            }
            logger.info("Filled \(label)")
            try await Task.sleep(for: .milliseconds(300))
        }

        // Done — therapist reviews and clicks "Sign and Complete" themselves
        onPhaseChange(.completed, "SOAP note entered. Please review and sign.")
    }

    // MARK: - CDP actions

    private func executeAction(_ action: StepAction, selector: String, cdp: CDPConnection) async throws {
        switch action {
        case .click:
            let js = """
                (() => {
                    const el = document.querySelector('\(selector.escapedForJS)');
                    if (el) { el.click(); return 'clicked'; }
                    // Fallback: find by text content
                    const all = document.querySelectorAll('a, button, [role="button"]');
                    for (const e of all) {
                        if (e.innerText.trim() === '\(selector.escapedForJS)') { e.click(); return 'clicked-by-text'; }
                    }
                    return 'not_found';
                })()
                """
            let result = try await cdp.evaluateJS(js)
            if result == "not_found" {
                throw EHRNavigatorError.elementNotFound(selector: selector)
            }

        case .navigate:
            let target = selector.hasPrefix("http") ? selector : selector
            _ = try await cdp.evaluateJS("window.location.href = '\(target.escapedForJS)'")

        case .fill:
            break // Handled in commitEntry

        case .wait:
            try await Task.sleep(for: .seconds(1))

        case .none:
            break
        }
    }

    // MARK: - DOM snapshot

    /// Gets a simplified DOM snapshot for the LLM. PHI is stripped.
    private func getDOMSnapshot(cdp: CDPConnection, patientName: String) async throws -> String {
        let js = """
            (() => {
                const elements = [];
                const walk = (el, depth) => {
                    if (depth > 6) return;
                    const tag = el.tagName?.toLowerCase() || '';
                    const role = el.getAttribute?.('role') || '';
                    const text = (el.innerText || '').substring(0, 100);
                    const href = el.getAttribute?.('href') || '';
                    const type = el.getAttribute?.('type') || '';
                    const placeholder = el.getAttribute?.('placeholder') || '';
                    const ariaLabel = el.getAttribute?.('aria-label') || '';
                    const isInteractive = ['A','BUTTON','INPUT','SELECT','TEXTAREA'].includes(el.tagName)
                        || role === 'button' || role === 'link' || role === 'tab';
                    if (isInteractive || (text.length > 0 && text.length < 200)) {
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

    private func connectToChrome(port: Int = 9222, ehrSystem: String? = nil) async throws -> CDPConnection {
        if let connection = try? await attemptCDPConnection(port: port) {
            return connection
        }

        logger.info("CDP: Chrome not available on port \(port), requesting relaunch")

        guard let onRelaunch = onChromeRelaunchNeeded,
              await onRelaunch() else {
            throw EHRNavigatorError.chromeRelaunchDeclined
        }

        let killProcess = Process()
        killProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killProcess.arguments = ["-9", "-f", "Google Chrome"]
        killProcess.standardOutput = FileHandle.nullDevice
        killProcess.standardError = FileHandle.nullDevice
        try? killProcess.run()
        killProcess.waitUntilExit()

        for _ in 1 ... 10 {
            try await Task.sleep(for: .milliseconds(500))
            let check = Process()
            check.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            check.arguments = ["-f", "Google Chrome"]
            check.standardOutput = FileHandle.nullDevice
            check.standardError = FileHandle.nullDevice
            try? check.run()
            check.waitUntilExit()
            if check.terminationStatus != 0 { break }
        }

        let chromePath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let profileDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pablo/ChromeDebugProfile")
            .path
        try? FileManager.default.createDirectory(atPath: profileDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: chromePath)
        var args = [
            "--remote-debugging-port=\(port)",
            "--user-data-dir=\(profileDir)",
            "--no-default-browser-check",
            "--no-first-run",
        ]
        if let ehr = ehrSystem, let loginURL = Self.ehrLoginURLs[ehr] {
            args.append(loginURL)
        }
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        for attempt in 1 ... 15 {
            try await Task.sleep(for: .seconds(1))
            if let connection = try? await attemptCDPConnection(port: port) {
                logger.info("CDP: Connected after relaunch (attempt \(attempt))")
                return connection
            }
        }

        throw EHRNavigatorError.browserNotFound
    }

    private func attemptCDPConnection(port: Int) async throws -> CDPConnection {
        guard let listURL = URL(string: "http://localhost:\(port)/json") else {
            throw EHRNavigatorError.browserNotFound
        }
        let (data, _) = try await URLSession.shared.data(from: listURL)
        guard let targets = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw EHRNavigatorError.browserNotFound
        }
        // Prefer a non-chrome:// page target
        let pageTarget = targets.first(where: {
            ($0["type"] as? String) == "page" && !(($0["url"] as? String)?.hasPrefix("chrome://") ?? true)
        }) ?? targets.first(where: { ($0["type"] as? String) == "page" })

        guard let target = pageTarget, let wsURL = target["webSocketDebuggerUrl"] as? String else {
            throw EHRNavigatorError.browserNotFound
        }
        let connection = CDPConnection(wsURL: wsURL)
        try await connection.connect()
        return connection
    }

    // MARK: - Matching (deterministic, no LLM)

    private func findPatientMatch(in pageText: String, name: String) throws -> String {
        if pageText.localizedCaseInsensitiveContains(name) { return name }
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            let reversed = "\(parts.last!), \(parts.first!)"
            if pageText.localizedCaseInsensitiveContains(reversed) { return String(reversed) }
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
                if pageText.localizedCaseInsensitiveContains(formatted) { return formatted }
            }
        }
        throw EHRNavigatorError.appointmentNotFound(time: time)
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
        guard let url = URL(string: wsURL) else { throw EHRNavigatorError.browserNotFound }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let ws = session.webSocketTask(with: url)
        self.webSocket = ws
        ws.resume()
        startReceiving()
        try await Task.sleep(for: .milliseconds(200))
    }

    func evaluateJS(_ expression: String) async throws -> String {
        let id = nextRequestID()
        let command: [String: Any] = [
            "id": id,
            "method": "Runtime.evaluate",
            "params": ["expression": expression, "returnByValue": true],
        ]
        return try await sendCommand(command, id: id)
    }

    private func nextRequestID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        return id
    }

    private func sendCommand(_ command: [String: Any], id: Int) async throws -> String {
        guard let ws = webSocket else { throw EHRNavigatorError.browserNotFound }
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
            case let .success(message): self?.handleMessage(message); self?.startReceiving()
            case let .failure(error): self?.logger.error("CDP WebSocket error: \(error.localizedDescription)")
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case let .string(text): data = Data(text.utf8)
        case let .data(d): data = d
        @unknown default: return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? Int else { return }

        lock.lock()
        let continuation = pendingCallbacks.removeValue(forKey: id)
        lock.unlock()

        if let result = json["result"] as? [String: Any],
           let innerResult = result["result"] as? [String: Any],
           let value = innerResult["value"] {
            if let s = value as? String { continuation?.resume(returning: s) }
            else if let b = value as? Bool { continuation?.resume(returning: b ? "true" : "false") }
            else { continuation?.resume(returning: String(describing: value)) }
        } else if let error = json["error"] as? [String: Any],
                  let msg = error["message"] as? String {
            continuation?.resume(throwing: EHRNavigatorError.actionFailed(action: "CDP", selector: msg))
        } else {
            continuation?.resume(returning: "")
        }
    }
}

// MARK: - String helper

extension String {
    var escapedForJS: String {
        self.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

// MARK: - Errors

enum EHRNavigatorError: LocalizedError {
    case browserNotFound
    case chromeRelaunchDeclined
    case patientNotFound(name: String)
    case appointmentNotFound(time: String)
    case elementNotFound(selector: String)
    case actionFailed(action: String, selector: String)
    case maxStepsExceeded

    var errorDescription: String? {
        switch self {
        case .browserNotFound:
            "Could not connect to Chrome. Make sure Chrome is running with --remote-debugging-port=9222"
        case .chromeRelaunchDeclined:
            "Chrome needs to be relaunched with debugging enabled to control the browser."
        case let .patientNotFound(name):
            "Could not find patient \"\(name)\" on the current page."
        case let .appointmentNotFound(time):
            "Could not find appointment at \(time) on the current page."
        case let .elementNotFound(selector):
            "Could not find element: \(selector)"
        case let .actionFailed(action, selector):
            "Failed to \(action): \(selector)"
        case .maxStepsExceeded:
            "Navigation took too many steps. The EHR layout may have changed significantly."
        }
    }
}
