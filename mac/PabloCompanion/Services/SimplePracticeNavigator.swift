import Foundation
import os

/// Deterministic browser navigation for SimplePractice EHR.
///
/// Uses known UI patterns (calendar URL, event selectors, button text)
/// instead of LLM-guided navigation. Faster, cheaper, and more reliable.
enum SimplePracticeNavigator {
    private static let logger = Logger(
        subsystem: AppConstants.appBundleID,
        category: "SimplePracticeNav"
    )

    // MARK: - Main entry point

    /// Navigates to the SOAP note editor using known SimplePractice patterns.
    ///
    /// Flow: calendar date → click event → Add/View Note → Edit → check template → form fields
    static func navigate(
        input: NoteEntryInput,
        cdp: CDPConnection,
        onPhaseChange: @escaping (SoapEntryPhase, String) -> Void
    ) async throws -> [String: String]? {
        // 1. Navigate to the correct calendar date
        let dateString = String(input.appointmentTime.prefix(10))
        onPhaseChange(.navigating, "Opening calendar for \(dateString)...")
        _ = try await cdp.evaluateJS(
            "window.location.href = '/calendar/appointments?currentDate=\(dateString)'"
        )
        try await Task.sleep(for: .seconds(2))
        logger.info("Navigated to calendar date \(dateString)")

        try await removeBlockingOverlays(cdp: cdp)

        // 2. Click the calendar event matching the time
        let displayTime = formatDisplayTime(from: input.appointmentTime)
        onPhaseChange(.navigating, "Finding \(displayTime) appointment...")
        try await clickCalendarEvent(cdp: cdp, displayTime: displayTime)

        // 3. Open the note (Add Note or View Note)
        onPhaseChange(.navigating, "Opening note...")
        try await clickNoteButton(cdp: cdp)

        // 4. Enter edit mode if in read-only view
        try await enterEditMode(cdp: cdp)
        try await removeBlockingOverlays(cdp: cdp)

        // 5. Check/switch note template
        onPhaseChange(.navigating, "Checking note template...")
        try await selectTemplate(cdp: cdp, noteType: input.noteType)

        // 6. Detect form fields
        onPhaseChange(.navigating, "Locating form fields...")
        return try await detectFormFields(cdp: cdp)
    }

    // MARK: - Navigation steps

    private static func clickCalendarEvent(
        cdp: CDPConnection,
        displayTime: String
    ) async throws {
        let result = try await cdp.evaluateJS("""
            (() => {
                const events = document.querySelectorAll('.fc-event');
                for (const ev of events) {
                    const text = ev.innerText || ev.textContent || '';
                    if (text.includes('\(displayTime.escapedForJS)')) {
                        ev.click();
                        return 'clicked_by_time';
                    }
                }
                if (events.length > 0) {
                    events[0].click();
                    return 'clicked_first';
                }
                return 'no_events';
            })()
        """)
        logger.info("Calendar event click: \(result)")
        if result == "no_events" {
            throw EHRNavigatorError.elementNotFound(
                selector: "calendar event for \(displayTime)"
            )
        }
        try await Task.sleep(for: .seconds(1))
    }

    private static func clickNoteButton(cdp: CDPConnection) async throws {
        let result = try await cdp.evaluateJS("""
            (() => {
                const all = document.querySelectorAll('a, button, [role="button"]');
                for (const el of all) {
                    const text = (el.innerText || '').trim();
                    if (text === 'Add Note' || text === 'View Note') {
                        el.click();
                        return 'clicked_' + text;
                    }
                }
                return 'not_found';
            })()
        """)
        logger.info("Note button: \(result)")
        if result == "not_found" {
            throw EHRNavigatorError.elementNotFound(
                selector: "Add Note / View Note button"
            )
        }
        try await Task.sleep(for: .seconds(2))
    }

    private static func enterEditMode(cdp: CDPConnection) async throws {
        let result = try await cdp.evaluateJS("""
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
        logger.info("Edit mode: \(result)")
        if result == "clicked_edit" {
            try await Task.sleep(for: .seconds(2))
        }
    }

    private static func selectTemplate(
        cdp: CDPConnection,
        noteType: String
    ) async throws {
        let escapedType = noteType.lowercased().escapedForJS
        let check = try await cdp.evaluateJS("""
            (() => {
                const trigger = document.querySelector(
                    '.questionnaires-dropdown .ember-basic-dropdown-trigger'
                );
                if (!trigger) return 'no_dropdown';
                const current = (trigger.innerText || '').trim();
                if (current.toLowerCase().includes('\(escapedType)'))
                    return 'correct';
                trigger.click();
                return 'opened:' + current;
            })()
        """)
        logger.info("Template check: \(check)")

        guard check.hasPrefix("opened") else { return }
        try await Task.sleep(for: .milliseconds(500))

        let selectResult = try await cdp.evaluateJS("""
            (() => {
                const selectors = [
                    '.ember-basic-dropdown-content li',
                    '.ember-basic-dropdown-content a',
                    '[class*="dropdown"] li',
                    '[class*="dropdown"] a'
                ];
                for (const sel of selectors) {
                    for (const el of document.querySelectorAll(sel)) {
                        const t = (el.innerText || '').trim();
                        if (t.toLowerCase().includes('\(escapedType)')) {
                            el.click();
                            return 'selected_' + t;
                        }
                    }
                }
                return 'template_not_found';
            })()
        """)
        logger.info("Template select: \(selectResult)")
        try await Task.sleep(for: .seconds(1))
    }

    private static func detectFormFields(
        cdp: CDPConnection
    ) async throws -> [String: String]? {
        let json = try await cdp.evaluateJS("""
            (() => {
                const editors = document.querySelectorAll(
                    '.ProseMirror[aria-label]'
                );
                if (editors.length === 0) return 'no_editors';
                const fields = {};
                editors.forEach((ed, i) => {
                    const label = ed.getAttribute('aria-label')
                        || ('free-text-' + (i + 1));
                    let labelEl = ed.previousElementSibling;
                    if (!labelEl)
                        labelEl = ed.parentElement?.previousElementSibling;
                    const name = (labelEl?.innerText || '')
                        .trim().toLowerCase();
                    const sel = ".ProseMirror[aria-label='"
                        + label + "']";
                    fields[name || 'field_' + (i + 1)] = sel;
                });
                return JSON.stringify(fields);
            })()
        """)
        logger.info("Form fields: \(json)")

        if json == "no_editors" {
            logger.warning("No ProseMirror editors found")
            return nil
        }
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(
                  with: data
              ) as? [String: String]
        else {
            logger.warning("Could not parse form fields: \(json)")
            return nil
        }
        logger.info("Deterministic nav complete. Fields: \(parsed)")
        return parsed
    }

    // MARK: - Helpers

    static func removeBlockingOverlays(cdp: CDPConnection) async throws {
        try await cdp.evaluateJS("""
            (() => {
                const blockers = [
                    'browser is outdated',
                    'browser is not supported',
                    'update your browser',
                    'unsupported browser'
                ];
                const els = document.querySelectorAll(
                    'h1, h2, h3, [role="dialog"], [role="alertdialog"]'
                );
                els.forEach(el => {
                    const text = (el.textContent || '').toLowerCase();
                    if (blockers.some(b => text.includes(b))) {
                        let c = el;
                        while (c.parentElement
                            && c.parentElement !== document.body)
                            c = c.parentElement;
                        c.remove();
                    }
                });
            })()
        """)
    }

    static func formatDisplayTime(from isoTime: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: isoTime) else { return "" }
        let display = DateFormatter()
        display.dateFormat = "h:mm a"
        return display.string(from: date)
    }
}
