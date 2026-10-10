using System.Runtime.InteropServices;
using Windows.Services.Store;

namespace PabloCompanion.Services;

/// <summary>What one Store check found.</summary>
public enum StoreUpdateCheck
{
    /// <summary>Not a Store install (the dev sideload, an unpackaged run). Stop checking.</summary>
    NotAvailable,

    /// <summary>Up to date.</summary>
    NoUpdates,

    /// <summary>An update is waiting; installing it restarts the app.</summary>
    UpdateReady,

    /// <summary>The check failed this time; try again on the next schedule.</summary>
    Failed,
}

/// <summary>The Store calls, behind a seam so the schedule is testable without the Store.</summary>
public interface IStoreUpdateClient
{
    /// <summary>Looks for an update to this app and, where the Store allows it, downloads it in the background.</summary>
    Task<StoreUpdateCheck> CheckAsync();

    /// <summary>Installs the waiting update. The Store closes the app to do it; the app is registered to start again.</summary>
    Task<bool> InstallAndRestartAsync();
}

/// <summary>
/// Keeps the Store build current. The Mac app has Sparkle; this is the Windows
/// counterpart, Store only (the sole sideloaded build is the dev one, where the
/// Store APIs have nothing to offer and every check no-ops).
///
/// Checks at launch and every <see cref="Interval"/> while idle. "Idle" is the
/// injected <c>isBusy</c> predicate: never while a session is starting or
/// recording, never while an upload is in flight. A check that comes due while busy
/// waits for the next idle tick rather than being skipped for six hours. When an
/// update is ready, <see cref="UpdateReady"/> asks the window to offer
/// "Restart to update"; nothing installs until the user picks Restart, and
/// <see cref="InstallAsync"/> checks idleness again at that moment.
/// </summary>
public sealed class StoreUpdateService : IDisposable
{
    /// <summary>How often an idle app checks the Store.</summary>
    public static readonly TimeSpan Interval = TimeSpan.FromHours(6);

    /// <summary>How often the schedule wakes to see whether a check is due and the app is idle.</summary>
    public static readonly TimeSpan TickInterval = TimeSpan.FromMinutes(1);

    private readonly IStoreUpdateClient _client;
    private readonly Func<bool> _isBusy;
    private readonly Func<DateTimeOffset> _now;
    private readonly TimeSpan _interval;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private DateTimeOffset? _nextDue;
    private bool _unavailable;
    private Timer? _timer;

    public StoreUpdateService(IStoreUpdateClient client, Func<bool> isBusy)
        : this(client, isBusy, () => DateTimeOffset.UtcNow, Interval)
    {
    }

    /// <summary>Clock- and interval-injectable overload for tests.</summary>
    internal StoreUpdateService(IStoreUpdateClient client, Func<bool> isBusy,
        Func<DateTimeOffset> now, TimeSpan interval)
    {
        _client = client;
        _isBusy = isBusy;
        _now = now;
        _interval = interval;
    }

    /// <summary>Raised (off the UI thread) when an update is downloaded or waiting to install.</summary>
    public event EventHandler? UpdateReady;

    /// <summary>True once an update is waiting for the user's Restart.</summary>
    public bool IsUpdateReady { get; private set; }

    /// <summary>Starts the schedule; the first check runs on the first idle tick. Idempotent.</summary>
    public void Start()
    {
        if (_timer != null) return;
        _timer = new Timer(async _ => await TickAsync(), null, TimeSpan.Zero, TickInterval);
    }

    public void Stop()
    {
        _timer?.Dispose();
        _timer = null;
    }

    /// <summary>One wake of the schedule: check the Store if a check is due and the app is idle.</summary>
    internal async Task TickAsync()
    {
        if (_unavailable || IsUpdateReady) return;
        var now = _now();
        if (_nextDue is { } due && now < due) return;
        if (_isBusy()) return;
        if (!_gate.Wait(0)) return;

        try
        {
            var result = await _client.CheckAsync();
            _nextDue = now + _interval;
            switch (result)
            {
                case StoreUpdateCheck.NotAvailable:
                    _unavailable = true;
                    App.Log("StoreUpdateService: not a Store install; update checks off");
                    Stop();
                    break;
                case StoreUpdateCheck.UpdateReady:
                    IsUpdateReady = true;
                    App.Log("StoreUpdateService: update ready");
                    UpdateReady?.Invoke(this, EventArgs.Empty);
                    break;
                case StoreUpdateCheck.Failed:
                    App.Log("StoreUpdateService: check failed; retrying on schedule");
                    break;
            }
        }
        catch (Exception ex)
        {
            _nextDue = now + _interval;
            App.LogException("StoreUpdateService.TickAsync", ex);
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>
    /// The user picked Restart. Installs only when idle (a session may have started
    /// while the prompt was open); returns false when it did not install.
    /// </summary>
    public async Task<bool> InstallAsync()
    {
        if (!IsUpdateReady || _isBusy()) return false;
        try
        {
            return await _client.InstallAndRestartAsync();
        }
        catch (Exception ex)
        {
            App.LogException("StoreUpdateService.InstallAsync", ex);
            return false;
        }
    }

    /// <summary>The user picked Later; the next scheduled check offers it again.</summary>
    public void Postpone()
    {
        IsUpdateReady = false;
        _nextDue = _now() + _interval;
    }

    public void Dispose() => Stop();
}

/// <summary>
/// The real Store calls: <c>StoreContext.GetDefault()</c>, then
/// <c>GetAppAndOptionalStorePackageUpdatesAsync</c>, a silent background
/// download where the Store permits one, and
/// <c>RequestDownloadAndInstallStorePackageUpdatesAsync</c> when the user picks
/// Restart. Installation is held until then because installing the app's own
/// package closes it.
/// </summary>
public sealed class StoreUpdateClient : IStoreUpdateClient
{
    private readonly Func<IntPtr> _windowHandle;
    private StoreContext? _context;
    private IReadOnlyList<StorePackageUpdate>? _updates;

    /// <param name="windowHandle">The main window, which owns any Store dialog.</param>
    public StoreUpdateClient(Func<IntPtr> windowHandle)
    {
        _windowHandle = windowHandle;
    }

    public async Task<StoreUpdateCheck> CheckAsync()
    {
        if (!PackageAppVersionProvider.HasPackageIdentity())
            return StoreUpdateCheck.NotAvailable;

        try
        {
            if (Windows.ApplicationModel.Package.Current.SignatureKind != Windows.ApplicationModel.PackageSignatureKind.Store)
                return StoreUpdateCheck.NotAvailable;

            var context = Context();
            var updates = await context.GetAppAndOptionalStorePackageUpdatesAsync();
            if (updates.Count == 0) return StoreUpdateCheck.NoUpdates;
            _updates = updates;

            // Fetch the bits now so Restart is quick. The silent call refuses
            // when the user has turned off Store auto-download; Restart then
            // downloads and installs in one step.
            if (context.CanSilentlyDownloadStorePackageUpdates)
                await context.TrySilentDownloadStorePackageUpdatesAsync(updates);
            return StoreUpdateCheck.UpdateReady;
        }
        catch (Exception ex)
        {
            // StoreContext throws when the app did not come from the Store (the
            // signature check above catches the usual case) and when the Store
            // is unreachable. Either way: log, do nothing, try again later.
            App.LogException("StoreUpdateClient.CheckAsync (Store unavailable)", ex);
            return StoreUpdateCheck.Failed;
        }
    }

    public async Task<bool> InstallAndRestartAsync()
    {
        if (_updates is not { Count: > 0 } updates) return false;

        // Installing closes the app; ask Windows to start it again afterwards.
        _ = RegisterApplicationRestart(null, 0);
        var result = await Context().RequestDownloadAndInstallStorePackageUpdatesAsync(updates);
        App.Log($"StoreUpdateClient: install finished, state={result.OverallState}");
        if (result.OverallState != StorePackageUpdateState.Completed) return false;

        // Still running (the Store did not need to close us): restart into the new version.
        Microsoft.Windows.AppLifecycle.AppInstance.Restart("");
        return true;
    }

    private StoreContext Context()
    {
        if (_context is not null) return _context;
        var context = StoreContext.GetDefault();
        // A desktop app must give Store dialogs an owner window.
        var hwnd = _windowHandle();
        if (hwnd != IntPtr.Zero) WinRT.Interop.InitializeWithWindow.Initialize(context, hwnd);
        _context = context;
        return context;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern int RegisterApplicationRestart(string? commandLine, int flags);
}
