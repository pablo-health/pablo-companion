using System.Diagnostics;
using System.Net.Http;
using PabloCompanion.Models;

namespace PabloCompanion.Services;

/// <summary>
/// Orchestrates EHR navigation: connect Chrome → navigate → verify → confirm → fill fields.
/// Currently supports SimplePractice only (deterministic navigation).
/// Mirrors EHRNavigator.swift on macOS.
/// </summary>
public sealed class EhrNavigator : IAsyncDisposable
{
    private CdpConnection? _cdp;
    private readonly int _debugPort;

    /// <summary>
    /// Callback invoked when Chrome needs to be (re)launched.
    /// Return true to proceed, false to abort.
    /// </summary>
    public Func<Task<bool>>? OnChromeRelaunchNeeded { get; set; }

    /// <summary>
    /// Callback invoked when the therapist needs to sign in to the EHR.
    /// Receives the EHR system name. Return true once signed in, false to abort.
    /// </summary>
    public Func<string, Task<bool>>? OnEhrLoginRequired { get; set; }

    public EhrNavigator(int debugPort = 9222)
    {
        _debugPort = debugPort;
    }

    /// <summary>
    /// Runs the full SOAP note entry flow: connect → navigate → verify → return confirmation.
    /// Does NOT fill the form — call <see cref="CommitEntryAsync"/> after therapist confirms.
    /// </summary>
    public async Task<SoapEntryConfirmation> NavigateToSoapFormAsync(
        NoteEntryInput input,
        Action<SoapEntryPhase, string>? onPhaseChange = null,
        CancellationToken ct = default)
    {
        // 1. Connect to Chrome
        onPhaseChange?.Invoke(SoapEntryPhase.Connecting, "Connecting to browser...");
        _cdp = await ConnectToChromeAsync(ct);

        // Install overlay-killer on future navigations
        await _cdp.AddScriptOnNewDocumentAsync(OverlayKillerScript, ct);
        await SimplePracticeNavigator.RemoveBlockingOverlaysAsync(_cdp, ct);

        // 2. Check for login page
        await EhrLoginDetector.WaitForLoginAsync(
            _cdp, input.EhrSystem, onPhaseChange, OnEhrLoginRequired, ct);

        // 3. Navigate (SimplePractice deterministic path)
        onPhaseChange?.Invoke(SoapEntryPhase.Navigating, "Navigating to note...");
        IReadOnlyDictionary<string, string>? formFields;

        if (input.EhrSystem.Equals("simplepractice", StringComparison.OrdinalIgnoreCase))
        {
            formFields = await SimplePracticeNavigator.NavigateAsync(input, _cdp, onPhaseChange, ct);
        }
        else
        {
            throw new EhrNavigatorException(
                $"EHR system '{input.EhrSystem}' is not yet supported. Only SimplePractice is available.");
        }

        // 4. Verify patient + time on the page
        onPhaseChange?.Invoke(SoapEntryPhase.MatchingPatient, "Verifying patient...");
        var (patientMatch, appointmentMatch) = await VerifyPatientAndTimeAsync(
            _cdp, input.PatientName, input.AppointmentDisplay, ct);

        // 5. Return confirmation for therapist review
        onPhaseChange?.Invoke(SoapEntryPhase.AwaitingConfirmation, "Ready for your review");
        return new SoapEntryConfirmation(
            PatientMatch: patientMatch,
            AppointmentMatch: appointmentMatch,
            EhrTargetField: "SimplePractice SOAP Note",
            SoapPreview: BuildSoapPreview(input),
            FormFields: formFields
        );
    }

    /// <summary>
    /// Fills the SOAP fields in the EHR. Call after therapist confirms.
    /// Fills but does NOT submit — therapist clicks Save/Sign themselves.
    /// </summary>
    public async Task CommitEntryAsync(
        NoteEntryInput input,
        IReadOnlyDictionary<string, string>? formFields,
        Action<SoapEntryPhase, string>? onPhaseChange = null,
        CancellationToken ct = default)
    {
        if (_cdp == null) throw new EhrNavigatorException("Not connected to Chrome");
        if (formFields == null || formFields.Count == 0)
            throw new EhrNavigatorException("No form fields detected");

        onPhaseChange?.Invoke(SoapEntryPhase.Entering, "Filling note...");

        foreach (var (label, content) in input.Sections)
        {
            // Find the matching form field by label
            var selector = formFields
                .FirstOrDefault(kv => kv.Key.Contains(label, StringComparison.OrdinalIgnoreCase))
                .Value;

            if (selector == null) continue;

            SelectorValidator.Validate(selector);

            var escaped = content
                .Replace("\\", "\\\\")
                .Replace("'", "\\'")
                .Replace("\n", "\\n")
                .Replace("\r", "\\r");

            await _cdp.EvaluateJsAsync($$"""
                (() => {
                    const el = document.querySelector('{{selector}}');
                    if (!el) return 'not_found';
                    el.focus();
                    el.innerHTML = '{{escaped}}';
                    el.dispatchEvent(new Event('input', { bubbles: true }));
                    el.dispatchEvent(new Event('change', { bubbles: true }));
                    return 'filled';
                })()
                """, ct);
        }

        onPhaseChange?.Invoke(SoapEntryPhase.Completed, "Note filled — please review and save");
    }

    /// <summary>
    /// Reads the current page text via CDP for verification.
    /// </summary>
    private static async Task<(string patientMatch, string appointmentMatch)> VerifyPatientAndTimeAsync(
        CdpConnection cdp, string patientName, string appointmentDisplay, CancellationToken ct)
    {
        var pageText = await cdp.EvaluateJsAsync(
            "document.body?.innerText?.substring(0, 5000) || ''", ct);

        var patientMatch = pageText.Contains(patientName, StringComparison.OrdinalIgnoreCase)
            ? $"Found: {patientName}"
            : $"Not verified: {patientName}";

        var appointmentMatch = !string.IsNullOrEmpty(appointmentDisplay)
            && pageText.Contains(appointmentDisplay, StringComparison.OrdinalIgnoreCase)
                ? $"Found: {appointmentDisplay}"
                : $"Time: {appointmentDisplay}";

        return (patientMatch, appointmentMatch);
    }

    private async Task<CdpConnection> ConnectToChromeAsync(CancellationToken ct)
    {
        var cdp = new CdpConnection();

        for (var attempt = 0; attempt < 15; attempt++)
        {
            try
            {
                await cdp.ConnectAsync(_debugPort, ct);
                return cdp;
            }
            catch (HttpRequestException) when (attempt == 0)
            {
                // Chrome not running — ask to launch
                if (OnChromeRelaunchNeeded != null)
                {
                    var approved = await OnChromeRelaunchNeeded();
                    if (!approved) throw new EhrNavigatorException("Chrome launch declined");
                }
                LaunchChromeWithDebugging();
            }
            catch (HttpRequestException)
            {
                // Still starting up — wait and retry
            }

            await Task.Delay(1000, ct);
        }

        throw new EhrNavigatorException("Could not connect to Chrome after 15 attempts");
    }

    private void LaunchChromeWithDebugging()
    {
        var profileDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Pablo", "ChromeDebugProfile");
        Directory.CreateDirectory(profileDir);

        // Try common Chrome locations
        var chromePaths = new[]
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                "Google", "Chrome", "Application", "chrome.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
                "Google", "Chrome", "Application", "chrome.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Google", "Chrome", "Application", "chrome.exe"),
        };

        var chromePath = chromePaths.FirstOrDefault(File.Exists)
            ?? throw new EhrNavigatorException("Google Chrome not found");

        Process.Start(new ProcessStartInfo
        {
            FileName = chromePath,
            Arguments = $"--remote-debugging-port={_debugPort} --user-data-dir=\"{profileDir}\" about:blank",
            UseShellExecute = false,
        });
    }

    private static string BuildSoapPreview(NoteEntryInput input)
    {
        return string.Join("\n\n", input.Sections.Select(s =>
            $"{s.Label.ToUpperInvariant()}:\n{(s.Content.Length > 100 ? s.Content[..100] + "..." : s.Content)}"));
    }

    public async ValueTask DisposeAsync()
    {
        if (_cdp != null)
        {
            await _cdp.DisposeAsync();
            _cdp = null;
        }
    }

    private const string OverlayKillerScript = """
        (new MutationObserver((mutations) => {
            const blockers = ['browser is outdated', 'browser is not supported',
                'update your browser', 'unsupported browser'];
            for (const m of mutations) {
                for (const node of m.addedNodes) {
                    if (node.nodeType !== 1) continue;
                    const text = (node.textContent || '').toLowerCase();
                    if (blockers.some(b => text.includes(b))) {
                        node.remove();
                    }
                }
            }
        })).observe(document.body || document.documentElement,
            { childList: true, subtree: true });
        """;
}
