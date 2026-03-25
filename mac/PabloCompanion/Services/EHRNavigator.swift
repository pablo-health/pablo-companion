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
    private let maxSteps = 15

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

        // Log Chrome version for diagnostics
        let versionInfo = try await connection.evaluateJS("navigator.userAgent")
        logger.info("Chrome user agent: \(versionInfo)")

        // Wait for page to fully load (Chrome was just launched with the EHR URL)
        try await Task.sleep(for: .seconds(2))

        // Install a persistent overlay killer. SimplePractice shows a "browser
        // outdated" overlay on EVERY route change (React SPA re-renders it).
        // A MutationObserver removes it instantly whenever it appears.
        try await connection.sendCommand(
            method: "Page.addScriptToEvaluateOnNewDocument",
            params: ["source": """
                const _killOverlay = () => {
                    document.querySelectorAll('h1').forEach(h1 => {
                        if (h1.textContent.includes('browser is outdated')) {
                            let el = h1;
                            while (el.parentElement && el.parentElement !== document.body) el = el.parentElement;
                            el.remove();
                        }
                    });
                };
                if (document.body) {
                    new MutationObserver(_killOverlay).observe(document.body, {childList:true, subtree:true});
                    _killOverlay();
                } else {
                    document.addEventListener('DOMContentLoaded', () => {
                        new MutationObserver(_killOverlay).observe(document.body, {childList:true, subtree:true});
                        _killOverlay();
                    });
                }
            """]
        )

        // Also remove it right now on the current page
        let removedOverlay = try await connection.evaluateJS("""
            (() => {
                const h1s = document.querySelectorAll('h1');
                for (const h1 of h1s) {
                    if (h1.textContent.includes('browser is outdated')) {
                        let el = h1;
                        while (el.parentElement && el.parentElement !== document.body) el = el.parentElement;
                        el.remove();
                        return 'removed';
                    }
                }
                return 'not_found';
            })()
        """)
        logger.info("Overlay status: \(removedOverlay)")

        onPhaseChange(.navigating, "Looking for the appointment...")
        let formFields: [String: String]?
        if input.ehrSystem == "simplepractice" {
            formFields = try await navigateSimplePracticeDeterministic(
                input: input, cdp: connection, onPhaseChange: onPhaseChange
            )
        } else {
            formFields = try await runNavigationLoop(
                input: input, cdp: connection, onPhaseChange: onPhaseChange
            )
        }

        onPhaseChange(.matchingPatient, "Verifying patient...")
        let pageText = try await connection.evaluateJS("document.body.innerText")

        // Try to verify patient/appointment on page, but don't fail if the note
        // editor doesn't show them (the LLM already confirmed we're on target).
        let patientMatch: String
        let appointmentMatch: String
        do {
            patientMatch = try findPatientMatch(in: pageText, name: input.patientName)
        } catch {
            logger.warning("Patient name not found on page, but LLM confirmed target. Proceeding.")
            patientMatch = input.patientName
        }
        do {
            appointmentMatch = try findAppointmentMatch(in: pageText, time: input.appointmentTime)
        } catch {
            logger.warning("Appointment time not found on page, but LLM confirmed target. Proceeding.")
            appointmentMatch = input.appointmentTime
        }

        return SoapEntryConfirmation(
            patientMatch: patientMatch,
            appointmentMatch: appointmentMatch,
            ehrTargetField: "\(input.ehrSystem) → \(input.noteType)",
            soapPreview: input.sections.first.map { "\($0.label.prefix(1)): \($0.content.prefix(80))..." },
            formFields: formFields
        )
    }

    // MARK: - SimplePractice deterministic navigation

    /// Navigates SimplePractice using known UI patterns — no LLM needed.
    ///
    /// Flow: calendar date → click event → Add/View Note → Edit → check template → form fields
    private func navigateSimplePracticeDeterministic(
        input: NoteEntryInput,
        cdp: CDPConnection,
        onPhaseChange: @escaping (SoapEntryPhase, String) -> Void
    ) async throws -> [String: String]? {
        let loginCallback = onEHRLoginRequired
        try await EHRLoginDetector.waitForLogin(
            cdp: cdp, ehrSystem: input.ehrSystem,
            onPhaseChange: onPhaseChange, onLoginRequired: loginCallback
        )

        // 1. Extract date from ISO timestamp and navigate directly
        let dateString = String(input.appointmentTime.prefix(10)) // "2026-03-23"
        onPhaseChange(.navigating, "Opening calendar for \(dateString)...")
        _ = try await cdp.evaluateJS(
            "window.location.href = '/calendar/appointments?currentDate=\(dateString)'"
        )
        try await Task.sleep(for: .seconds(2))
        logger.info("Navigated to calendar date \(dateString)")

        // 2. Remove overlays
        try await removeBlockingOverlays(cdp: cdp)

        // 3. Format the appointment time for text matching (e.g. "8:00 PM")
        let displayTime = extractDisplayTime(from: input.appointmentTime)
        onPhaseChange(.navigating, "Finding \(displayTime) appointment...")

        // 4. Click the calendar event matching the time
        let clickResult = try await cdp.evaluateJS("""
            (() => {
                // Try to find event by time text
                const events = document.querySelectorAll('.fc-event');
                for (const ev of events) {
                    const text = ev.innerText || ev.textContent || '';
                    if (text.includes('\(displayTime.escapedForJS)')) {
                        ev.click();
                        return 'clicked_by_time';
                    }
                }
                // Fallback: click first event on the page
                if (events.length > 0) {
                    events[0].click();
                    return 'clicked_first';
                }
                return 'no_events';
            })()
        """)
        logger.info("Calendar event click: \(clickResult)")
        if clickResult == "no_events" {
            throw EHRNavigatorError.elementNotFound(selector: "calendar event for \(displayTime)")
        }
        try await Task.sleep(for: .seconds(1))

        // 5. Click "Add Note" or "View Note" in the flyout
        onPhaseChange(.navigating, "Opening note...")
        let noteButtonResult = try await cdp.evaluateJS("""
            (() => {
                const all = document.querySelectorAll('a, button, [role="button"]');
                for (const el of all) {
                    const text = (el.innerText || '').trim();
                    if (text === 'Add Note' || text === 'View Note') {
                        el.click();
                        return 'clicked_' + text.toLowerCase().replace(' ', '_');
                    }
                }
                return 'not_found';
            })()
        """)
        logger.info("Note button: \(noteButtonResult)")
        if noteButtonResult == "not_found" {
            throw EHRNavigatorError.elementNotFound(selector: "Add Note / View Note button")
        }
        try await Task.sleep(for: .seconds(2))

        // 6. Check if we're in read-only mode (Edit button visible)
        let editResult = try await cdp.evaluateJS("""
            (() => {
                const all = document.querySelectorAll('a, button, [role="button"]');
                for (const el of all) {
                    const text = (el.innerText || '').trim();
                    if (text === 'Edit') {
                        el.click();
                        return 'clicked_edit';
                    }
                }
                return 'already_editing';
            })()
        """)
        logger.info("Edit mode: \(editResult)")
        if editResult == "clicked_edit" {
            try await Task.sleep(for: .seconds(2))
        }

        // 7. Remove overlays again (SPA re-renders them)
        try await removeBlockingOverlays(cdp: cdp)

        // 8. Check/switch note template
        onPhaseChange(.navigating, "Checking note template...")
        let templateResult = try await cdp.evaluateJS("""
            (() => {
                // Check current template name
                const trigger = document.querySelector('.questionnaires-dropdown .ember-basic-dropdown-trigger');
                if (!trigger) return 'no_dropdown';
                const currentTemplate = (trigger.innerText || '').trim();
                if (currentTemplate.toLowerCase().includes('\(input.noteType.lowercased().escapedForJS)')) {
                    return 'correct_template';
                }
                // Need to switch — open dropdown and select
                trigger.click();
                return 'opened_dropdown:' + currentTemplate;
            })()
        """)
        logger.info("Template check: \(templateResult)")

        if templateResult.hasPrefix("opened_dropdown") {
            try await Task.sleep(for: .milliseconds(500))
            // Select the right template from the dropdown
            let selectResult = try await cdp.evaluateJS("""
                (() => {
                    const items = document.querySelectorAll(
                        '.ember-basic-dropdown-content li, ' +
                        '.ember-basic-dropdown-content a, ' +
                        '[class*="dropdown"] li, [class*="dropdown"] a'
                    );
                    for (const item of items) {
                        const text = (item.innerText || '').trim();
                        if (text.toLowerCase().includes('\(input.noteType.lowercased().escapedForJS)')) {
                            item.click();
                            return 'selected_' + text;
                        }
                    }
                    // Fallback: click by text content anywhere
                    const all = document.querySelectorAll('*');
                    for (const el of all) {
                        if (el.children.length === 0) {
                            const text = (el.innerText || '').trim();
                            if (text.toLowerCase() === '\(input.noteType.lowercased().escapedForJS)') {
                                el.click();
                                return 'selected_fallback_' + text;
                            }
                        }
                    }
                    return 'template_not_found';
                })()
            """)
            logger.info("Template select: \(selectResult)")
            try await Task.sleep(for: .seconds(1))
        }

        // 9. Detect form fields
        onPhaseChange(.navigating, "Locating form fields...")
        let fieldsJSON = try await cdp.evaluateJS("""
            (() => {
                const editors = document.querySelectorAll('.ProseMirror[aria-label]');
                if (editors.length === 0) return 'no_editors';
                const fields = {};
                editors.forEach((ed, i) => {
                    const label = ed.getAttribute('aria-label') || ('free-text-' + (i + 1));
                    // Try to find the section label above this editor
                    let labelEl = ed.previousElementSibling;
                    if (!labelEl) labelEl = ed.parentElement?.previousElementSibling;
                    const sectionName = (labelEl?.innerText || '').trim().toLowerCase();
                    const selector = ".ProseMirror[aria-label='" + label + "']";
                    if (sectionName) {
                        fields[sectionName] = selector;
                    } else {
                        fields['field_' + (i + 1)] = selector;
                    }
                });
                return JSON.stringify(fields);
            })()
        """)
        logger.info("Form fields: \(fieldsJSON)")

        if fieldsJSON == "no_editors" {
            logger.warning("No ProseMirror editors found — may not be on edit page")
            return nil
        }

        // Parse the JSON fields
        guard let data = fieldsJSON.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            logger.warning("Could not parse form fields JSON: \(fieldsJSON)")
            return nil
        }

        logger.info("✅ SimplePractice deterministic nav complete. Fields: \(parsed)")
        return parsed
    }

    /// Removes known blocking overlays from the page.
    private func removeBlockingOverlays(cdp: CDPConnection) async throws {
        try await cdp.evaluateJS("""
            (() => {
                const blockers = ['browser is outdated', 'browser is not supported',
                    'update your browser', 'unsupported browser'];
                document.querySelectorAll('h1, h2, h3, [role="dialog"], [role="alertdialog"]').forEach(el => {
                    const text = (el.textContent || '').toLowerCase();
                    if (blockers.some(b => text.includes(b))) {
                        let container = el;
                        while (container.parentElement && container.parentElement !== document.body)
                            container = container.parentElement;
                        container.remove();
                    }
                });
            })()
        """)
    }

    /// Extracts display time (e.g. "8:00 PM") from ISO timestamp.
    private func extractDisplayTime(from isoTime: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: isoTime) else { return "" }
        let display = DateFormatter()
        display.dateFormat = "h:mm a"
        return display.string(from: date)
    }

    // MARK: - LLM navigation loop (experimental)

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
            // Remove known blocking overlays before snapshot.
            // The LLM also tries to dismiss overlays by clicking close buttons.
            // This is the fallback for overlays the LLM can't dismiss.
            try await cdp.evaluateJS("""
                (() => {
                    const blockers = ['browser is outdated', 'browser is not supported',
                        'update your browser', 'unsupported browser'];
                    document.querySelectorAll('h1, h2, h3, [role="dialog"], [role="alertdialog"]').forEach(el => {
                        const text = (el.textContent || '').toLowerCase();
                        if (blockers.some(b => text.includes(b))) {
                            let container = el;
                            while (container.parentElement && container.parentElement !== document.body)
                                container = container.parentElement;
                            container.remove();
                        }
                    });
                })()
            """)

            let currentURL = try await cdp.evaluateJS("window.location.href")
            let domSnapshot = try await getDOMSnapshot(cdp: cdp, patientName: input.patientName)

            logger.info("""
            ── NAV STEP \(step) ──
              URL: \(currentURL)
              Goal: \(goal)
              DOM (\(domSnapshot.count) chars): \(domSnapshot.prefix(300))…
              Previous actions: \(previousActions.map { "\($0.action)→\($0.target)=\($0.result)" })
            """)

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

            logger.info("Step \(step): \(response.action.rawValue) → \(response.selector) (confidence: \(response.confidence))")
            onPhaseChange(.navigating, "Step \(step): \(response.reasoning)")

            if response.isOnTargetPage, response.formFields != nil {
                logger.info("✅ On target page after \(step) step(s). formFields: \(response.formFields?.description ?? "nil")")
                return response.formFields
            } else if response.isOnTargetPage {
                // LLM says we're on target but didn't return form fields — not actually there yet.
                // Add this to context so the LLM knows to look harder or navigate further.
                logger.warning("LLM claimed target page but no formFields — continuing navigation")
                previousActions.append(PreviousAction(
                    action: "none", target: "target_page_check",
                    result: "claimed on target but no form fields found — need ProseMirror editors with labels"
                ))
                continue
            }

            let result = await executeStepSafely(response: response, cdp: cdp)
            logger.info("Step \(step) result: \(result.action)→\(result.target) = \(result.result)")
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
            const navTags = new Set(['A','BUTTON','NAV','H1','H2','H3','H4','H5','H6','LABEL','TH','LI','SPAN']);
            const navRoles = new Set(['button','link','tab','menuitem','option','heading','navigation','listbox','dialog','tabpanel']);
            const skipTags = new Set(['SCRIPT','STYLE','NOSCRIPT','SVG','PATH','LINK','META','HEAD',
                                     'script','style','noscript','svg','path','link','meta','head',
                                     'SYMBOL','symbol','DEFS','defs','clipPath','linearGradient']);
            const elements = [];
            const walk = (el, depth) => {
                if (depth > 15) return;
                if (elements.length > 400) return;
                if (skipTags.has(el.tagName) || skipTags.has(el.tagName?.toLowerCase())) return;
                const tag = el.tagName?.toLowerCase() || '';
                const role = el.getAttribute?.('role') || '';
                const href = el.getAttribute?.('href') || '';
                const type = el.getAttribute?.('type') || '';
                const cls = (typeof el.className === 'string' ? el.className : el.className?.baseVal || '').substring(0, 60);
                const ariaLabel = el.getAttribute?.('aria-label') || '';
                const placeholder = el.getAttribute?.('placeholder') || '';
                const dataId = el.getAttribute?.('data-id') || '';
                const isNav = navTags.has(el.tagName) || navRoles.has(role);
                const isInteractive = ['INPUT','SELECT','TEXTAREA'].includes(el.tagName);
                const isClickable = el.onclick || el.getAttribute?.('data-event-id') || cls.includes('event') || cls.includes('appointment');
                const hasDirectText = el.childNodes && Array.from(el.childNodes).some(n => n.nodeType === 3 && n.textContent.trim().length > 0);
                if (!isNav && !isInteractive && !isClickable && !hasDirectText && !el.children?.length) return;
                const indent = '  '.repeat(Math.min(depth, 6));
                let desc = `${indent}<${tag}`;
                if (role) desc += ` role="${role}"`;
                if (href) desc += ` href="${href}"`;
                if (type) desc += ` type="${type}"`;
                if (cls) desc += ` class="${cls}"`;
                if (ariaLabel) desc += ` aria-label="${ariaLabel}"`;
                if (placeholder) desc += ` placeholder="${placeholder}"`;
                if (dataId) desc += ` data-id="${dataId}"`;
                if (isNav || isClickable || hasDirectText) {
                    const text = (el.innerText || '').substring(0, 60).replace(/\\n/g, ' ').trim();
                    if (text) desc += `>${text}`;
                    else desc += `>`;
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
            "--remote-allow-origins=*",
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
        // Retry up to 3 times — target IDs can change while the page is loading
        for attempt in 1 ... 3 {
            let wsURL = try await fetchPageTargetURL(port: port)
            do {
                let connection = CDPConnection(wsURL: wsURL)
                try await connection.connect()
                return connection
            } catch {
                logger.info("CDP connect attempt \(attempt) failed: \(error.localizedDescription)")
                if attempt < 3 {
                    try await Task.sleep(for: .seconds(1))
                }
            }
        }
        throw EHRNavigatorError.browserNotFound
    }

    private func fetchPageTargetURL(port: Int) async throws -> String {
        guard let listURL = URL(string: "http://127.0.0.1:\(port)/json") else {
            throw EHRNavigatorError.browserNotFound
        }
        let (data, _) = try await URLSession.shared.data(from: listURL)
        guard let targets = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw EHRNavigatorError.browserNotFound
        }
        let pageTarget = targets.first(where: {
            ($0["type"] as? String) == "page" && !(($0["url"] as? String)?.hasPrefix("chrome://") ?? true)
        }) ?? targets.first(where: { ($0["type"] as? String) == "page" })

        guard let target = pageTarget, let wsURL = target["webSocketDebuggerUrl"] as? String else {
            throw EHRNavigatorError.browserNotFound
        }
        // Force IPv4 — Chrome may only listen on 127.0.0.1, not ::1
        return wsURL.replacingOccurrences(of: "ws://localhost:", with: "ws://127.0.0.1:")
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
