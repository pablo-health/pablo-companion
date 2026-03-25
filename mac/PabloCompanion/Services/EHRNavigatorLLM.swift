import Foundation
import os

/// LLM-based navigation for EHR systems (experimental).
///
/// Uses goal-based prompting: sends DOM snapshots to the backend LLM
/// which decides what to click next. Works across different EHR systems
/// but is slower and less reliable than deterministic navigators.
extension EHRNavigator {
    // MARK: - LLM navigation loop

    func runNavigationLoop(
        input: NoteEntryInput,
        cdp: CDPConnection,
        onPhaseChange: @escaping (SoapEntryPhase, String) -> Void
    ) async throws -> [String: String]? {
        let goal = buildGoal(input: input)
        var previousActions: [PreviousAction] = []

        let loginCallback = onEHRLoginRequired
        try await EHRLoginDetector.waitForLogin(
            cdp: cdp, ehrSystem: input.ehrSystem,
            onPhaseChange: onPhaseChange,
            onLoginRequired: loginCallback
        )

        for step in 1 ... maxSteps {
            let result = try await executeNavigationStep(
                step: step, goal: goal, input: input,
                cdp: cdp, previousActions: &previousActions,
                onPhaseChange: onPhaseChange
            )
            if let fields = result { return fields }
        }
        return nil
    }

    // swiftlint:disable:next function_body_length function_parameter_count
    private func executeNavigationStep(
        step: Int, goal: String, input: NoteEntryInput,
        cdp: CDPConnection,
        previousActions: inout [PreviousAction],
        onPhaseChange: @escaping (SoapEntryPhase, String) -> Void
    ) async throws -> [String: String]?? {
        try await SimplePracticeNavigator.removeBlockingOverlays(
            cdp: cdp
        )
        let currentURL = try await cdp.evaluateJS(
            "window.location.href"
        )
        let domSnapshot = try await getDOMSnapshot(
            cdp: cdp, patientName: input.patientName
        )

        logNavigationStep(NavStepContext(
            step: step, url: currentURL, goal: goal,
            domSnapshot: domSnapshot,
            previousActions: previousActions
        ))

        let response = try await apiClient.navigate(
            request: GoalNavigationRequest(
                ehrSystem: input.ehrSystem, goal: goal,
                currentUrl: currentURL,
                domSnapshot: domSnapshot,
                previousActions: previousActions,
                failedAction: nil
            )
        )

        let action = response.action.rawValue
        logger.info(
            "Step \(step): \(action) → \(response.selector)"
        )
        onPhaseChange(
            .navigating, "Step \(step): \(response.reasoning)"
        )

        if response.isOnTargetPage, response.formFields != nil {
            return response.formFields
        } else if response.isOnTargetPage {
            previousActions.append(PreviousAction(
                action: "none", target: "target_page_check",
                result: "no form fields found"
            ))
            return nil
        }

        let result = await executeStepSafely(
            response: response, cdp: cdp
        )
        previousActions.append(result)
        try await Task.sleep(for: .milliseconds(800))
        return nil
    }

    // MARK: - Helpers

    private func buildGoal(input: NoteEntryInput) -> String {
        "Navigate to the \(input.noteType) form "
        + "for the appointment at \(input.appointmentDisplay)"
    }

    private struct NavStepContext {
        let step: Int
        let url: String
        let goal: String
        let domSnapshot: String
        let previousActions: [PreviousAction]
    }

    private func logNavigationStep(_ ctx: NavStepContext) {
        let actions = ctx.previousActions.map {
            "\($0.action)→\($0.target)=\($0.result)"
        }
        logger.info("""
        ── NAV STEP \(ctx.step) ──
          URL: \(ctx.url)
          Goal: \(ctx.goal)
          DOM (\(ctx.domSnapshot.count) chars): \(ctx.domSnapshot.prefix(300))…
          Previous actions: \(actions)
        """)
    }

    private func executeStepSafely(
        response: GoalNavigationResponse,
        cdp: CDPConnection
    ) async -> PreviousAction {
        do {
            try await executeAction(
                response.action,
                selector: response.selector,
                cdp: cdp
            )
            return PreviousAction(
                action: response.action.rawValue,
                target: response.selector,
                result: "success"
            )
        } catch {
            logger.warning(
                "Step failed: \(error.localizedDescription)"
            )
            return PreviousAction(
                action: response.action.rawValue,
                target: response.selector,
                result: "failed: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - CDP actions

    private func executeAction(
        _ action: StepAction,
        selector: String,
        cdp: CDPConnection
    ) async throws {
        try SelectorValidator.validate(selector)

        switch action {
        case .click:
            let escaped = selector.escapedForJS
            let js = """
            (() => {
                const el = document.querySelector('\(escaped)');
                if (el) { el.click(); return 'clicked'; }
                const all = document.querySelectorAll(
                    'a, button, [role="button"]'
                );
                for (const e of all) {
                    if (e.innerText.trim() === '\(escaped)') {
                        e.click();
                        return 'clicked-by-text';
                    }
                }
                return 'not_found';
            })()
            """
            let result = try await cdp.evaluateJS(js)
            if result == "not_found" {
                throw EHRNavigatorError.elementNotFound(
                    selector: selector
                )
            }

        case .navigate:
            _ = try await cdp.evaluateJS(
                "window.location.href = '\(selector.escapedForJS)'"
            )

        case .fill:
            break

        case .wait:
            try await Task.sleep(for: .seconds(1))

        case .none:
            break
        }
    }

    // MARK: - DOM snapshot (HIPAA-safe)

    func getDOMSnapshot(
        cdp: CDPConnection,
        patientName: String
    ) async throws -> String {
        let rawSnapshot = try await cdp.evaluateJS(Self.domSnapshotJS)
        return PHISanitizer.strip(
            from: rawSnapshot, patientName: patientName
        )
    }

    private static let domSnapshotJS = """
    (() => {
        const navTags = new Set([
            'A','BUTTON','NAV','H1','H2','H3','H4','H5','H6',
            'LABEL','TH','LI','SPAN'
        ]);
        const navRoles = new Set([
            'button','link','tab','menuitem','option',
            'heading','navigation','listbox','dialog','tabpanel'
        ]);
        const skipTags = new Set([
            'SCRIPT','STYLE','NOSCRIPT','SVG','PATH','LINK',
            'META','HEAD','SYMBOL','DEFS',
            'script','style','noscript','svg','path','link',
            'meta','head','symbol','defs','clipPath',
            'linearGradient'
        ]);
        const elements = [];
        const walk = (el, depth) => {
            if (depth > 15) return;
            if (elements.length > 400) return;
            const tn = el.tagName || '';
            if (skipTags.has(tn) || skipTags.has(tn.toLowerCase()))
                return;
            const tag = tn.toLowerCase();
            const role = el.getAttribute?.('role') || '';
            const href = el.getAttribute?.('href') || '';
            const type = el.getAttribute?.('type') || '';
            const cls = (typeof el.className === 'string'
                ? el.className
                : el.className?.baseVal || ''
            ).substring(0, 60);
            const ariaLabel = el.getAttribute?.('aria-label') || '';
            const ph = el.getAttribute?.('placeholder') || '';
            const did = el.getAttribute?.('data-id') || '';
            const isNav = navTags.has(tn) || navRoles.has(role);
            const isInput = ['INPUT','SELECT','TEXTAREA']
                .includes(tn);
            const isClick = el.onclick
                || el.getAttribute?.('data-event-id')
                || cls.includes('event')
                || cls.includes('appointment');
            const hasTxt = el.childNodes
                && Array.from(el.childNodes).some(
                    n => n.nodeType === 3
                    && n.textContent.trim().length > 0
                );
            if (!isNav && !isInput && !isClick && !hasTxt
                && !el.children?.length) return;
            const indent = '  '.repeat(Math.min(depth, 6));
            let desc = `${indent}<${tag}`;
            if (role) desc += ` role="${role}"`;
            if (href) desc += ` href="${href}"`;
            if (type) desc += ` type="${type}"`;
            if (cls) desc += ` class="${cls}"`;
            if (ariaLabel) desc += ` aria-label="${ariaLabel}"`;
            if (ph) desc += ` placeholder="${ph}"`;
            if (did) desc += ` data-id="${did}"`;
            if (isNav || isClick || hasTxt) {
                const text = (el.innerText || '')
                    .substring(0, 60)
                    .replace(/\\n/g, ' ')
                    .trim();
                desc += text ? `>${text}` : `>`;
            } else if (isInput) {
                desc += `>[field]`;
            } else {
                desc += `>`;
            }
            elements.push(desc);
            for (const child of (el.children || []))
                walk(child, depth + 1);
        };
        walk(document.body, 0);
        return elements.join('\\n');
    })()
    """
}
