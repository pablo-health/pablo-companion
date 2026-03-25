using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace PabloCompanion.Services;

/// <summary>
/// Monitors system-wide user input idle time for HIPAA-compliant session timeout.
/// Two triggers:
/// 1. Idle timeout — polls GetLastInputInfo every 60s, fires after 15 minutes
/// 2. Screen lock — fires immediately via SessionSwitch event
/// </summary>
public sealed class InactivityMonitor : IDisposable
{
    private const int TimeoutMinutes = 15;
    private readonly System.Threading.Timer _timer;

    public event Action? OnTimeout;
    public event Action? OnScreenLocked;

    [StructLayout(LayoutKind.Sequential)]
    private struct LASTINPUTINFO
    {
        public uint cbSize;
        public uint dwTime;
    }

    [DllImport("user32.dll")]
    private static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    public InactivityMonitor()
    {
        _timer = new System.Threading.Timer(
            CheckIdle, null, TimeSpan.FromMinutes(1), TimeSpan.FromMinutes(1));

        SystemEvents.SessionSwitch += OnSessionSwitch;
    }

    private void OnSessionSwitch(object? sender, SessionSwitchEventArgs e)
    {
        if (e.Reason == SessionSwitchReason.SessionLock)
        {
            OnScreenLocked?.Invoke();
        }
    }

    private void CheckIdle(object? state)
    {
        var info = new LASTINPUTINFO { cbSize = (uint)Marshal.SizeOf<LASTINPUTINFO>() };
        if (!GetLastInputInfo(ref info)) return;

        var idleMs = (uint)Environment.TickCount - info.dwTime;
        if (idleMs >= TimeoutMinutes * 60u * 1000u)
        {
            OnTimeout?.Invoke();
        }
    }

    public void Dispose()
    {
        _timer.Dispose();
        SystemEvents.SessionSwitch -= OnSessionSwitch;
    }
}
