using PabloCompanion.Services;

namespace PabloCompanion.ViewModels;

/// <summary>
/// Offers "Say hello to Pablo" once, the first time a signed-in clinician
/// reaches the main window. Skippable; Settings > Check audio reruns it.
/// Mirrors <c>AudioCheckOnFirstUse.swift</c>.
///
/// <para>Never while recording, starting a session, or holding a launch that
/// is waiting for Start Recording: the check runs its own capture, and two
/// captures can't share the devices. The window gets a second to settle before
/// the dialog lands on it, and becoming busy in that second calls it off until
/// the next <see cref="Update"/> finds the window free again.</para>
/// </summary>
public sealed class AudioCheckFirstUse
{
    public static readonly TimeSpan SettleDelay = TimeSpan.FromSeconds(1);

    private readonly IAudioCheckSettings _settings;
    private readonly Func<TimeSpan, CancellationToken, Task> _delay;
    private readonly object _gate = new();
    private CancellationTokenSource? _pending;
    private bool _busy = true;

    public AudioCheckFirstUse(IAudioCheckSettings settings)
        : this(settings, Task.Delay)
    {
    }

    /// <summary>Test seam: a delay the test controls in place of the real second.</summary>
    internal AudioCheckFirstUse(IAudioCheckSettings settings, Func<TimeSpan, CancellationToken, Task> delay)
    {
        _settings = settings;
        _delay = delay;
    }

    /// <summary>Raised once, when the check should be shown. Raised on the caller's context.</summary>
    public event EventHandler? OfferRequested;

    /// <summary>
    /// Call whenever the window becomes visible or anything that makes it busy
    /// changes. Busy cancels a pending offer; free starts the settle delay.
    /// </summary>
    public void Update(bool isBusy)
    {
        CancellationTokenSource pending;
        lock (_gate)
        {
            _busy = isBusy;
            if (isBusy)
            {
                _pending?.Cancel();
                _pending = null;
                return;
            }
            if (_pending is not null || _settings.Offered) return;
            pending = new CancellationTokenSource();
            _pending = pending;
        }
        _ = OfferAfterSettleAsync(pending);
    }

    private async Task OfferAfterSettleAsync(CancellationTokenSource pending)
    {
        try
        {
            await _delay(SettleDelay, pending.Token);
        }
        catch (OperationCanceledException)
        {
            return;
        }

        lock (_gate)
        {
            if (!ReferenceEquals(_pending, pending)) return;
            _pending = null;
            if (pending.IsCancellationRequested || _busy || _settings.Offered) return;
            _settings.Offered = true;
        }
        OfferRequested?.Invoke(this, EventArgs.Empty);
    }
}
