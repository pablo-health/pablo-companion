using CommunityToolkit.Mvvm.ComponentModel;
using PabloCompanion.Models;
using PabloCompanion.Services;

namespace PabloCompanion.ViewModels;

/// <summary>
/// Decides when the update-required screen replaces the window. Mirrors
/// <c>versionBlock</c> / <c>checkVersionCompatibility()</c> in macOS
/// <c>ContentView.swift</c>: the launch health check sets it once, and once set it
/// stays (no dismiss, no bypass).
///
/// Windows adds one rule the Mac does not need: a requirement that arrives while a
/// recording is active (a 426 mid-session) waits. The recording and its upload are
/// the user's work; the screen shows as soon as the recording ends.
/// <see cref="Reevaluate"/> is called whenever recording state changes.
/// </summary>
public sealed partial class UpdateGateViewModel : ObservableObject
{
    private readonly IAppVersionProvider _version;
    private readonly Func<bool> _recordingActive;
    private UpdateRequiredReason? _pending;
    private string? _knownMinClientVersion;

    /// <param name="version">This app's version, for the screen's copy.</param>
    /// <param name="recordingActive">True while a session is starting or recording; the screen waits until it is false.</param>
    public UpdateGateViewModel(IAppVersionProvider version, Func<bool> recordingActive)
    {
        _version = version;
        _recordingActive = recordingActive;
    }

    /// <summary>What the window shows instead of its content, or null for the normal app.</summary>
    [ObservableProperty]
    public partial UpdateRequiredReason? Shown { get; private set; }

    /// <summary>A requirement waiting for the recording to end.</summary>
    public bool IsDeferred => _pending is not null && Shown is null;

    /// <summary>
    /// The launch check. A client too old for the backend, or a backend too old for
    /// this client, blocks the window; a compatible pair changes nothing.
    /// </summary>
    public void ApplyHealth(HealthStatus status)
    {
        _knownMinClientVersion = status.MinClientVersion;
        if (status.ClientUpdateRequired)
            Require(UpdateRequiredReason.ClientUpdate(_version.Version, status.MinClientVersion));
        else if (status.ServerUpdateRequired)
            Require(UpdateRequiredReason.ServerUpdate(status.ServerVersion, status.MinServerVersion));
    }

    /// <summary>A 426 from any request: the backend no longer supports this version.</summary>
    public void ReportUpdateRequired()
        => Require(UpdateRequiredReason.ClientUpdate(_version.Version, _knownMinClientVersion));

    /// <summary>Routes every 426 the client sees to <see cref="ReportUpdateRequired"/>.</summary>
    public void Attach(APIClient api) => api.UpdateRequiredDetected += _ => ReportUpdateRequired();

    /// <summary>Shows a deferred requirement once no recording is active.</summary>
    public void Reevaluate()
    {
        if (_pending is null || Shown is not null || _recordingActive()) return;
        Shown = _pending;
        OnPropertyChanged(nameof(IsDeferred));
    }

    private void Require(UpdateRequiredReason reason)
    {
        if (Shown is not null) return;
        // A client update outranks a server one: it is the one the user can act on.
        if (_pending is null || reason.Kind == UpdateRequiredKind.ClientUpdate)
            _pending = reason;
        if (_recordingActive())
        {
            App.Log("UpdateGate: update required; waiting for the recording to end");
            OnPropertyChanged(nameof(IsDeferred));
            return;
        }
        Reevaluate();
    }
}
