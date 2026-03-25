using PabloCompanion.Models;

namespace PabloCompanion.Services;

/// <summary>
/// Deterministic browser navigation for SimplePractice EHR.
/// Uses known UI patterns (calendar URL, event selectors, button text)
/// instead of LLM-guided navigation. Faster, cheaper, and more reliable.
/// Mirrors SimplePracticeNavigator.swift on macOS.
/// </summary>
internal static class SimplePracticeNavigator
{
    /// <summary>
    /// Navigates to the SOAP note editor using known SimplePractice patterns.
    /// Flow: calendar date → click event → Add/View Note → Edit → check template → form fields.
    /// </summary>
    public static async Task<IReadOnlyDictionary<string, string>?> NavigateAsync(
        NoteEntryInput input,
        CdpConnection cdp,
        Action<SoapEntryPhase, string>? onPhaseChange = null,
        CancellationToken ct = default)
    {
        // 1. Navigate to the correct calendar date
        var dateString = input.AppointmentTime[..10]; // "2026-03-23"
        onPhaseChange?.Invoke(SoapEntryPhase.Navigating, $"Opening calendar for {dateString}...");
        await cdp.EvaluateJsAsync(
            $"window.location.href = '/calendar/appointments?currentDate={EscapeJs(dateString)}'", ct);
        await Task.Delay(2000, ct);

        await RemoveBlockingOverlaysAsync(cdp, ct);

        // 2. Click the calendar event matching the time
        var displayTime = FormatDisplayTime(input.AppointmentTime);
        onPhaseChange?.Invoke(SoapEntryPhase.Navigating, $"Finding {displayTime} appointment...");
        await ClickCalendarEventAsync(cdp, displayTime, ct);

        // 3. Open the note (Add Note or View Note)
        onPhaseChange?.Invoke(SoapEntryPhase.Navigating, "Opening note...");
        await ClickNoteButtonAsync(cdp, ct);

        // 4. Enter edit mode if in read-only view
        await EnterEditModeAsync(cdp, ct);
        await RemoveBlockingOverlaysAsync(cdp, ct);

        // 5. Check/switch note template
        onPhaseChange?.Invoke(SoapEntryPhase.Navigating, "Checking note template...");
        await SelectTemplateAsync(cdp, input.NoteType, ct);

        // 6. Detect form fields
        onPhaseChange?.Invoke(SoapEntryPhase.Navigating, "Locating form fields...");
        return await DetectFormFieldsAsync(cdp, ct);
    }

    private static async Task ClickCalendarEventAsync(
        CdpConnection cdp, string displayTime, CancellationToken ct)
    {
        var result = await cdp.EvaluateJsAsync($$"""
            (() => {
                const events = document.querySelectorAll('.fc-event');
                for (const ev of events) {
                    const text = ev.innerText || ev.textContent || '';
                    if (text.includes('{{EscapeJs(displayTime)}}')) {
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
            """, ct);

        if (result == "no_events")
        {
            throw new EhrNavigatorException(
                $"No calendar events found for {displayTime}");
        }
        await Task.Delay(1000, ct);
    }

    private static async Task ClickNoteButtonAsync(CdpConnection cdp, CancellationToken ct)
    {
        var result = await cdp.EvaluateJsAsync("""
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
            """, ct);

        if (result == "not_found")
        {
            throw new EhrNavigatorException("Add Note / View Note button not found");
        }
        await Task.Delay(2000, ct);
    }

    private static async Task EnterEditModeAsync(CdpConnection cdp, CancellationToken ct)
    {
        var result = await cdp.EvaluateJsAsync("""
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
            """, ct);

        if (result == "clicked_edit")
        {
            await Task.Delay(2000, ct);
        }
    }

    private static async Task SelectTemplateAsync(
        CdpConnection cdp, string noteType, CancellationToken ct)
    {
        var escapedType = EscapeJs(noteType.ToLowerInvariant());
        var check = await cdp.EvaluateJsAsync($$"""
            (() => {
                const trigger = document.querySelector(
                    '.questionnaires-dropdown .ember-basic-dropdown-trigger'
                );
                if (!trigger) return 'no_dropdown';
                const current = (trigger.innerText || '').trim();
                if (current.toLowerCase().includes('{{escapedType}}'))
                    return 'correct';
                trigger.click();
                return 'opened:' + current;
            })()
            """, ct);

        if (!check.StartsWith("opened", StringComparison.Ordinal))
            return;

        await Task.Delay(500, ct);

        await cdp.EvaluateJsAsync($$"""
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
                        if (t.toLowerCase().includes('{{escapedType}}')) {
                            el.click();
                            return 'selected_' + t;
                        }
                    }
                }
                return 'template_not_found';
            })()
            """, ct);

        await Task.Delay(1000, ct);
    }

    internal static async Task<IReadOnlyDictionary<string, string>?> DetectFormFieldsAsync(
        CdpConnection cdp, CancellationToken ct)
    {
        var json = await cdp.EvaluateJsAsync("""
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
            """, ct);

        if (json == "no_editors")
            return null;

        try
        {
            return System.Text.Json.JsonSerializer.Deserialize<Dictionary<string, string>>(json);
        }
        catch
        {
            return null;
        }
    }

    internal static async Task RemoveBlockingOverlaysAsync(CdpConnection cdp, CancellationToken ct)
    {
        await cdp.EvaluateJsAsync("""
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
            """, ct);
    }

    /// <summary>
    /// Formats an ISO 8601 time to display format (e.g. "8:00 PM").
    /// </summary>
    internal static string FormatDisplayTime(string isoTime)
    {
        if (DateTimeOffset.TryParse(isoTime, out var dt))
        {
            return dt.ToString("h:mm tt");
        }
        return "";
    }

    private static string EscapeJs(string value)
    {
        return value
            .Replace("\\", "\\\\")
            .Replace("'", "\\'")
            .Replace("\n", "\\n")
            .Replace("\r", "\\r");
    }
}
