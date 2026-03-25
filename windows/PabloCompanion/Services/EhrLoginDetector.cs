using PabloCompanion.Models;

namespace PabloCompanion.Services;

/// <summary>
/// Detects EHR login pages and waits for the therapist to sign in.
/// Checks for password fields, login-related URLs, and common login page text.
/// Mirrors EHRLoginDetector.swift on macOS.
/// </summary>
internal static class EhrLoginDetector
{
    /// <summary>
    /// Waits for the therapist to sign in if a login page is detected.
    /// Returns immediately if already signed in.
    /// </summary>
    public static async Task WaitForLoginAsync(
        CdpConnection cdp,
        string ehrSystem,
        Action<SoapEntryPhase, string>? onPhaseChange = null,
        Func<string, Task<bool>>? onLoginRequired = null,
        CancellationToken ct = default)
    {
        var isLogin = await DetectLoginPageAsync(cdp, ct);
        if (!isLogin) return;

        onPhaseChange?.Invoke(SoapEntryPhase.Navigating, "Please sign in to your EHR...");

        if (onLoginRequired != null)
        {
            var signedIn = await onLoginRequired(ehrSystem);
            if (!signedIn)
            {
                throw new EhrNavigatorException("Therapist declined to sign in");
            }
        }

        // Poll until login page is gone (max 2 minutes)
        for (var i = 0; i < 60; i++)
        {
            await Task.Delay(2000, ct);
            var stillLogin = await DetectLoginPageAsync(cdp, ct);
            if (!stillLogin)
            {
                onPhaseChange?.Invoke(SoapEntryPhase.Navigating, "Signed in. Navigating...");
                await Task.Delay(1000, ct);
                return;
            }
        }

        throw new EhrNavigatorException("Timed out waiting for EHR login");
    }

    /// <summary>
    /// Checks if the current page looks like a login page.
    /// </summary>
    internal static async Task<bool> DetectLoginPageAsync(CdpConnection cdp, CancellationToken ct = default)
    {
        var result = await cdp.EvaluateJsAsync("""
            (() => {
                const url = window.location.href.toLowerCase();
                const text = document.body?.innerText?.toLowerCase() || '';
                const hasPasswordField = !!document.querySelector('input[type="password"]');
                const urlHints = ['login', 'signin', 'sign-in', 'auth', 'sso'];
                const textHints = ['sign in', 'log in', 'username', 'forgot password'];
                const urlMatch = urlHints.some(h => url.includes(h));
                const textMatch = textHints.some(h => text.includes(h));
                return (hasPasswordField || urlMatch || textMatch) ? 'true' : 'false';
            })()
            """, ct);

        return result == "true";
    }
}
