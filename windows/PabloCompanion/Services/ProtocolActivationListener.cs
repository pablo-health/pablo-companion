namespace PabloCompanion.Services;

/// <summary>
/// Bridges Windows protocol activation events (`pablohealth://...`) into an
/// awaitable Task for the OAuth flow.
///
/// Replaces the loopback HTTP listener pattern (RFC 8252 §7.3) with custom
/// URL scheme activation (RFC 8252 §7.1), which is the canonical packaged-app
/// pattern: no AppContainer loopback exemption required, OS-arbitrated redirect.
///
/// Usage:
///   1. AuthViewModel calls WaitForCallbackAsync before opening the browser
///   2. Browser redirects to pablohealth://callback?code=...&state=...
///   3. Windows reactivates the app; the activation handler calls Deliver
///   4. The awaiting AuthViewModel resumes with the URI
/// </summary>
public sealed class ProtocolActivationListener
{
    private readonly Lock _gate = new();
    private TaskCompletionSource<Uri>? _pending;

    /// <summary>
    /// Returns a task that completes when the next pablohealth:// activation
    /// arrives, or throws TimeoutException after the given duration. If a previous
    /// wait is outstanding, it is cancelled and replaced.
    /// </summary>
    public Task<Uri> WaitForCallbackAsync(TimeSpan timeout, CancellationToken ct = default)
    {
        var tcs = new TaskCompletionSource<Uri>(TaskCreationOptions.RunContinuationsAsynchronously);

        lock (_gate)
        {
            _pending?.TrySetCanceled();
            _pending = tcs;
        }

        var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeout);
        cts.Token.Register(() =>
        {
            lock (_gate)
            {
                if (_pending == tcs)
                {
                    _pending = null;
                }
            }
            tcs.TrySetException(new TimeoutException("Sign-in timed out. Please try again."));
        }, useSynchronizationContext: false);

        return tcs.Task;
    }

    /// <summary>
    /// Called from the protocol-activation handler when Windows reactivates the
    /// app with a pablohealth:// URI. If no auth flow is awaiting, the URI is
    /// discarded (e.g., user clicked a stale callback link manually).
    /// </summary>
    public void Deliver(Uri uri)
    {
        TaskCompletionSource<Uri>? tcs;
        lock (_gate)
        {
            tcs = _pending;
            _pending = null;
        }
        tcs?.TrySetResult(uri);
    }
}
