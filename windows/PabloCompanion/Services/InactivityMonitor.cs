using System.Runtime.InteropServices;

namespace PabloCompanion.Services;

/// <summary>
/// Monitors system-wide user input idle time for HIPAA-compliant session timeout.
/// Polls Win32 GetLastInputInfo every 60 seconds; fires OnTimeout after 15 minutes.
/// </summary>
public sealed class InactivityMonitor : IDisposable
{
    private const int TimeoutMinutes = 15;
    private readonly System.Threading.Timer _timer;

    public event Action? OnTimeout;

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

    public void Dispose() => _timer.Dispose();
}
