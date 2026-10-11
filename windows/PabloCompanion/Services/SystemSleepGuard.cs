using System.Collections.Concurrent;
using System.Runtime.InteropServices;

namespace PabloCompanion.Services;

/// <summary>
/// Keeps the PC from going to sleep while a session is recording. The screen may
/// still turn off or lock; only system sleep is held off, because a sleeping PC
/// stops the capture mid-session.
/// </summary>
public interface ISystemSleepGuard
{
    /// <summary>Asks Windows not to sleep until <see cref="AllowSleep"/>. Safe to call again while held.</summary>
    void KeepAwake();

    /// <summary>Lets Windows sleep again. Safe to call when nothing is held.</summary>
    void AllowSleep();
}

/// <summary>
/// <see cref="ISystemSleepGuard"/> over <c>SetThreadExecutionState</c>.
///
/// <para>The execution state belongs to the thread that sets it and lasts until
/// that thread changes it or exits, so every call is made on one dedicated
/// background thread owned by this class. A caller on any thread (the UI thread,
/// or a capture callback continuing on the thread pool) therefore sets and clears
/// the same state, and nothing is left held by a pool thread that never clears it.</para>
/// </summary>
public sealed class SystemSleepGuard : ISystemSleepGuard, IDisposable
{
    private const uint EsContinuous = 0x80000000;
    private const uint EsSystemRequired = 0x00000001;

    private readonly BlockingCollection<uint> _requests = [];
    private readonly Thread _thread;

    public SystemSleepGuard()
    {
        _thread = new Thread(Run) { IsBackground = true, Name = "Pablo sleep guard" };
        _thread.Start();
    }

    [DllImport("kernel32.dll")]
    private static extern uint SetThreadExecutionState(uint esFlags);

    // Not ES_DISPLAY_REQUIRED: the screen may lock while the therapist is in the
    // session; the system must not sleep.
    public void KeepAwake() => Post(EsContinuous | EsSystemRequired);

    public void AllowSleep() => Post(EsContinuous);

    private void Post(uint flags)
    {
        try
        {
            _requests.Add(flags);
        }
        catch (InvalidOperationException)
        {
            // Disposed at shutdown; the state goes with the thread.
        }
    }

    private void Run()
    {
        foreach (var flags in _requests.GetConsumingEnumerable())
        {
            if (SetThreadExecutionState(flags) == 0)
                App.Log($"SleepGuard: SetThreadExecutionState failed flags=0x{flags:X8}");
        }
    }

    public void Dispose() => _requests.CompleteAdding();
}

/// <summary>Holds nothing. For a <see cref="ViewModels.RecordingViewModel"/> built without a guard (tests).</summary>
internal sealed class NoSleepGuard : ISystemSleepGuard
{
    public static readonly NoSleepGuard Instance = new();

    public void KeepAwake()
    {
    }

    public void AllowSleep()
    {
    }
}
