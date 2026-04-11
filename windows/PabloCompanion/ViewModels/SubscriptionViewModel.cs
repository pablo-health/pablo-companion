using System.Net.Http;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Xaml;
using PabloCompanion.Models;
using PabloCompanion.Services;

namespace PabloCompanion.ViewModels;

/// <summary>
/// Manages subscription status and the one-time grace extension.
/// Mirrors SubscriptionViewModel.swift on macOS.
/// </summary>
public partial class SubscriptionViewModel : ObservableObject
{
    private readonly APIClient _apiClient;
    private DispatcherTimer? _pollingTimer;

    [ObservableProperty]
    public partial SubscriptionInfo? Info { get; set; }

    [ObservableProperty]
    public partial bool IsExtending { get; set; }

    [ObservableProperty]
    public partial string? ExtensionError { get; set; }

    public SubscriptionViewModel(APIClient apiClient)
    {
        _apiClient = apiClient;
    }

    // --- Fetch ---

    [RelayCommand]
    public async Task RefreshStatusAsync()
    {
        try
        {
            Info = await _apiClient.FetchSubscriptionStatusAsync();
        }
        catch (Exception)
        {
            // Non-fatal — subscription banner is informational, not blocking.
        }
    }

    // --- Grace Extension ---

    [RelayCommand]
    public async Task RequestExtensionAsync()
    {
        IsExtending = true;
        ExtensionError = null;

        try
        {
            Info = await _apiClient.ExtendSubscriptionAsync();
        }
        catch (PabloException ex)
        {
            ExtensionError = ex.StatusCode == 409
                ? "Extension already used"
                : "Something went wrong. Please contact support@pablo.health";
        }
        catch (HttpRequestException)
        {
            ExtensionError = "Network error — check your connection and try again";
        }
        finally
        {
            IsExtending = false;
        }
    }

    // --- Computed State ---

    /// <summary>
    /// Whether the banner should be shown (any non-active subscription state).
    /// </summary>
    public bool ShouldShowBanner => Info != null && BannerKind != "hidden";

    /// <summary>
    /// Banner kind: "trial", "past_due", "canceled", "grace_active", or "hidden".
    /// </summary>
    public string BannerKind
    {
        get
        {
            if (Info == null) return "hidden";

            // Check for active grace extension first.
            if (Info.GraceExtensionExpiresAt is { } expiresStr &&
                DateTimeOffset.TryParse(expiresStr, out var expires) &&
                expires > DateTimeOffset.UtcNow)
            {
                return "grace_active";
            }

            return Info.Status switch
            {
                "active" => "hidden",
                "trial" => "trial",
                "past_due" => "past_due",
                "canceled" => "canceled",
                _ => "hidden",
            };
        }
    }

    public int? TrialSessionsRemaining =>
        Info is { TrialSessionsUsed: { } used, TrialSessionsLimit: { } limit }
            ? Math.Max(0, limit - used)
            : null;

    public int? TrialDaysRemaining
    {
        get
        {
            if (Info?.TrialStart is not { } startStr ||
                Info?.TrialDaysLimit is not { } daysLimit ||
                !DateTimeOffset.TryParse(startStr, out var start))
                return null;

            var elapsed = (int)(DateTimeOffset.UtcNow - start).TotalDays;
            return Math.Max(0, daysLimit - elapsed);
        }
    }

    public DateTimeOffset? GraceExpiresAt =>
        Info?.GraceExtensionExpiresAt is { } s &&
        DateTimeOffset.TryParse(s, out var d)
            ? d
            : null;

    // --- Polling ---

    public void StartPolling()
    {
        StopPolling();
        _pollingTimer = new DispatcherTimer { Interval = TimeSpan.FromMinutes(10) };
        _pollingTimer.Tick += async (_, _) => await RefreshStatusAsync();
        _pollingTimer.Start();
    }

    public void StopPolling()
    {
        _pollingTimer?.Stop();
        _pollingTimer = null;
    }

    /// <summary>
    /// Clears subscription data on sign-out.
    /// </summary>
    public void ClearAllData()
    {
        StopPolling();
        Info = null;
        ExtensionError = null;
    }

    partial void OnInfoChanged(SubscriptionInfo? value)
    {
        OnPropertyChanged(nameof(ShouldShowBanner));
        OnPropertyChanged(nameof(BannerKind));
        OnPropertyChanged(nameof(TrialSessionsRemaining));
        OnPropertyChanged(nameof(TrialDaysRemaining));
        OnPropertyChanged(nameof(GraceExpiresAt));
    }
}
