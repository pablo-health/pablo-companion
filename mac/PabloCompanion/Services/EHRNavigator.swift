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
        input: NoteEntryInput,
        onPhaseChange: @escaping (SoapEntryPhase, String) -> Void
    ) async throws -> SoapEntryConfirmation {
        onPhaseChange(.connecting, "Connecting to browser...")
        let connection = try await connectToChrome(ehrSystem: input.ehrSystem)
        self.cdp = connection

        onPhaseChange(.navigating, "Looking for the appointment...")
        let formFields = try await runNavigationLoop(input: input, cdp: connection, onPhaseChange: onPhaseChange)

        onPhaseChange(.matchingPatient, "Verifying patient...")
        let pageText = try await connection.evaluateJS("document.body.innerText")
        let patientMatch = try findPatientMatch(in: pageText, name: input.patientName)
        let appointmentMatch = try findAppointmentMatch(in: pageText, time: input.appointmentTime)

        return SoapEntryConfirmation(
            patientMatch: patientMatch,
            appointmentMatch: appointmentMatch,
            ehrTargetField: "\(input.ehrSystem) → \(input.noteType)",
            soapPreview: input.sections.first.map { "\($0.label.prefix(1)): \($0.content.prefix(80))..." },
            formFields: formFields
        )
    }

    // MARK: - Navigation loop

    /// Called when the EHR login page is detected. The UI should prompt the
    /// therapist to sign in and return `true` once they have.
    var onEHRLoginRequired: ((_ ehrSystem: String) async -> Bool)?

    private func runNavigationLoop(
        input: NoteEntryInput,
        cdp: CDPConnection,
        onPhaseChange: @escaping (SoapEntryPhase, String) -> Void
    ) async throws -> [String: String]? {
        let goal = "Navigate to the \(input.noteType) form for the appointment at \(input.appointmentDisplay)"
        var previousActions: [PreviousAction] = []

        let loginCallback = onEHRLoginRequired
        try await EHRLoginDetector.waitForLogin(
            cdp: cdp,
            ehrSystem: input.ehrSystem,
            onPhaseChange: onPhaseChange,
            onLoginRequired: loginCallback
        )

        for step in 1 ... maxSteps {
            let currentURL = try await cdp.evaluateJS("window.location.href")
            let domSnapshot = try await getDOMSnapshot(cdp: cdp, patientName: input.patientName)

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

            logger.info("Step \(step): \(response.action.rawValue) → \(response.selector)")
            onPhaseChange(.navigating, "Step \(step): \(response.reasoning)")

            if response.isOnTargetPage {
                logger.info("On target page after \(step) step(s)")
                return response.formFields
            }

            let result = await executeStepSafely(response: response, cdp: cdp)
            previousActions.append(result)
            try await Task.sleep(for: .milliseconds(800))
        }
        return nil
    }

    private func executeStepSafely(response: GoalNavigationResponse, cdp: CDPConnection) async -> PreviousAction {
        do {
            try await executeAction(response.action, selector: response.selector, cdp: cdp)
            return PreviousAction(action: response.action.rawValue, target: response.selector, result: "success")
        } catch {
            logger.warning("Step failed: \(error.localizedDescription)")
            return PreviousAction(
                action: response.action.rawValue,
                target: response.selector,
                result: "failed: \(error.localizedDescription)"
            )
        }
    }

    /// After therapist confirms, fill the note fields and leave for them to review/submit.
    func commitEntry(
        input: NoteEntryInput,
        formFields: [String: String]?,
        onPhaseChange: @escaping (SoapEntryPhase, String) -> Void
    ) async throws {
        guard let cdp else {
            throw EHRNavigatorError.browserNotFound
        }

        onPhaseChange(.entering, "Entering note...")

        for (index, section) in input.sections.enumerated() {
            let label = section.label
            let content = section.content

            // Try LLM-identified selector first, then fall back to position
            let selector = formFields?[label.lowercased()]
                ?? ".ProseMirror[aria-label='free-text-\(index + 1)']"

            onPhaseChange(.entering, "Filling \(label.capitalized)...")
            let escaped = content.escapedForJS
            let selectorEscaped = selector.escapedForJS

            // Works for both ProseMirror (innerHTML) and textarea (.value)
            let js = """
            (() => {
                let el = document.querySelector('\(selectorEscaped)');
                // Fallback: nth textarea
                if (!el) {
                    const all = document.querySelectorAll('textarea.expanding-textarea, .ProseMirror');
                    el = all[\(index)];
                }
                if (!el) return 'NOT_FOUND';
                el.focus();
                if (el.contentEditable === 'true') {
                    el.innerHTML = '<p>\(escaped)</p>';
                } else {
                    el.value = '\(escaped)';
                }
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

        // Done — therapist reviews and clicks save/sign themselves
        onPhaseChange(.completed, "Note entered. Please review and sign.")
    }

    // MARK: - CDP actions

    private func executeAction(_ action: StepAction, selector: String, cdp: CDPConnection) async throws {
        try SelectorValidator.validate(selector)

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

    // MARK: - DOM snapshot (HIPAA-safe)

    /// Gets a navigation-only DOM snapshot for the LLM.
    ///
    /// Security: only sends structural/interactive elements to the LLM.
    /// Text content is included ONLY for navigation elements (links, buttons,
    /// tabs, headings). All other text is replaced with `[content]`.
    /// PHI (patient names, phone, email, DOB, diagnosis codes) is stripped.
    private func getDOMSnapshot(cdp: CDPConnection, patientName: String) async throws -> String {
        let js = """
        (() => {
            const navTags = new Set(['A','BUTTON','NAV','H1','H2','H3','H4','H5','H6','LABEL','TH']);
            const navRoles = new Set(['button','link','tab','menuitem','option','heading','navigation']);
            const elements = [];
            const walk = (el, depth) => {
                if (depth > 6) return;
                const tag = el.tagName?.toLowerCase() || '';
                const role = el.getAttribute?.('role') || '';
                const href = el.getAttribute?.('href') || '';
                const type = el.getAttribute?.('type') || '';
                const ariaLabel = el.getAttribute?.('aria-label') || '';
                const placeholder = el.getAttribute?.('placeholder') || '';
                const isNav = navTags.has(el.tagName) || navRoles.has(role);
                const isInteractive = ['INPUT','SELECT','TEXTAREA'].includes(el.tagName);
                if (!isNav && !isInteractive && !el.children?.length) return;
                const indent = '  '.repeat(depth);
                let desc = `${indent}<${tag}`;
                if (role) desc += ` role="${role}"`;
                if (href) desc += ` href="${href}"`;
                if (type) desc += ` type="${type}"`;
                if (ariaLabel) desc += ` aria-label="${ariaLabel}"`;
                if (placeholder) desc += ` placeholder="${placeholder}"`;
                if (isNav) {
                    const text = (el.innerText || '').substring(0, 40).replace(/\\n/g, ' ');
                    desc += `>${text}`;
                } else if (isInteractive) {
                    desc += `>[field]`;
                } else {
                    desc += `>`;
                }
                elements.push(desc);
                for (const child of (el.children || [])) walk(child, depth + 1);
            };
            walk(document.body, 0);
            return elements.join('\\n');
        })()
        """
        let rawSnapshot = try await cdp.evaluateJS(js)
        return PHISanitizer.strip(from: rawSnapshot, patientName: patientName)
    }

    // MARK: - CDP connection

    private func connectToChrome(port: Int = 9222, ehrSystem: String? = nil) async throws -> CDPConnection {
        if let connection = try? await attemptCDPConnection(port: port) {
            return connection
        }

        logger.info("CDP: Chrome not available on port \(port), requesting relaunch")

        guard let onRelaunch = onChromeRelaunchNeeded,
              await onRelaunch()
        else {
            throw EHRNavigatorError.chromeRelaunchDeclined
        }

        try await killAllChromeProcesses()
        try launchChromeWithDebugging(port: port, ehrSystem: ehrSystem)

        for attempt in 1 ... 15 {
            try await Task.sleep(for: .seconds(1))
            if let connection = try? await attemptCDPConnection(port: port) {
                logger.info("CDP: Connected after relaunch (attempt \(attempt))")
                return connection
            }
        }

        throw EHRNavigatorError.browserNotFound
    }

    private func killAllChromeProcesses() async throws {
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
    }

    private func launchChromeWithDebugging(port: Int, ehrSystem: String?) throws {
        let chromePath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let profileDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pablo/ChromeDebugProfile").path
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
    }

    private func attemptCDPConnection(port: Int) async throws -> CDPConnection {
        guard let listURL = URL(string: "http://127.0.0.1:\(port)/json") else {
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
        // Chrome reports ws://localhost but may only listen on IPv4.
        // Force 127.0.0.1 to avoid IPv6 resolution failures.
        let fixedURL = wsURL.replacingOccurrences(of: "ws://localhost:", with: "ws://127.0.0.1:")
        let connection = CDPConnection(wsURL: fixedURL)
        try await connection.connect()
        return connection
    }

    // MARK: - Matching (deterministic, no LLM)

    private func findPatientMatch(in pageText: String, name: String) throws -> String {
        if pageText.localizedCaseInsensitiveContains(name) { return name }
        let parts = name.split(separator: " ")
        if let last = parts.last, let first = parts.first, parts.count >= 2 {
            let reversed = "\(last), \(first)"
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

    // MARK: - CDP lifecycle

    /// Disconnects CDP and optionally kills the debug Chrome profile.
    func disconnect(killChrome: Bool = false) {
        cdp = nil
        if killChrome {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            process.arguments = ["-f", "Pablo/ChromeDebugProfile"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            logger.info("Killed debug Chrome profile")
        }
        logger.info("CDP disconnected")
    }

    /// Clears cookies from the debug Chrome profile directory.
    func clearDebugProfileCookies() {
        let profileDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pablo/ChromeDebugProfile")
        let cookieFiles = ["Cookies", "Cookies-journal"]
        for file in cookieFiles {
            let path = profileDir.appendingPathComponent("Default/\(file)")
            try? FileManager.default.removeItem(at: path)
        }
        logger.info("Cleared debug Chrome profile cookies")
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
