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

    private readonly CredentialManager? _credentials;

    public SubscriptionViewModel(APIClient apiClient, CredentialManager? credentials = null)
    {
        _apiClient = apiClient;
        _credentials = credentials;
    }

    // --- Fetch ---

    [RelayCommand]
    public async Task RefreshStatusAsync()
    {
        try
        {
            Info = await _apiClient.FetchSubscriptionStatusAsync();
        }
        catch (PabloException)
        {
            // Non-fatal — banner is informational.
        }
        catch (HttpRequestException)
        {
            // Non-fatal — banner is informational.
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
    /// Banner kind: "trial", "trial_expired", "past_due", "canceled",
    /// "subscription_needed", "grace_active", or "hidden".
    /// </summary>
    /// <remarks>
    /// Only "active" hides the banner. A status this build does not know is not
    /// active, and the server will refuse new sessions on it, so it shows the
    /// generic "subscription_needed" banner rather than nothing.
    /// </remarks>
    public string BannerKind
    {
        get
        {
            if (Info == null) return "hidden";

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
                "trial_expired" => "trial_expired",
                "past_due" => "past_due",
                "canceled" => "canceled",
                _ => "subscription_needed",
            };
        }
    }

    /// <summary>
    /// The kinds that mean new sessions are refused until billing is sorted out.
    /// These carry the Manage subscription button.
    /// </summary>
    public bool IsLapsed => BannerKind is "trial_expired" or "past_due" or "canceled" or "subscription_needed";

    /// <summary>Copy for the trial banner.</summary>
    public string TrialText
    {
        get
        {
            var parts = new List<string>();
            if (TrialSessionsRemaining is { } sessions)
                parts.Add($"{sessions} session{(sessions == 1 ? "" : "s")} remaining");
            if (TrialDaysRemaining is { } days)
                parts.Add($"{days} day{(days == 1 ? "" : "s")} left");
            return parts.Count > 0
                ? $"Free trial \u2014 {string.Join(", ", parts)}"
                : "You're on a free trial";
        }
    }

    /// <summary>Copy for the lapsed banner; null when the banner is not lapsed.</summary>
    public string? LapsedHeading => BannerKind switch
    {
        "trial_expired" => "Your free trial has ended. Subscribe to keep recording sessions.",
        "canceled" => "Your subscription has ended. Resubscribe to keep recording sessions.",
        "past_due" => "Your payment needs attention",
        "subscription_needed" => "Subscribe to keep recording sessions.",
        _ => null,
    };

    /// <summary>
    /// Shown when the server refuses to start a session on the subscription.
    /// </summary>
    public const string StartBlockedMessage = "Subscribe to start sessions.";

    /// <summary>
    /// The web billing page the Manage subscription button opens, on the server
    /// this device signed in to.
    /// </summary>
    public Uri ManageSubscriptionUrl
    {
        get
        {
            var server = _credentials?.AuthServerUrl;
            if (string.IsNullOrWhiteSpace(server)) server = AppConstants.DefaultAuthServerUrl;
            return new Uri($"{server.TrimEnd('/')}/dashboard/billing");
        }
    }

    /// <summary>
    /// Refreshes the banner whenever <paramref name="sessionVm"/> reports that the
    /// server refused a session on the subscription, so the clinician sees why
    /// without restarting. The flag is reset so the next refusal fires again.
    /// </summary>
    public void WatchForSubscriptionRefusals(SessionViewModel sessionVm)
    {
        sessionVm.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(SessionViewModel.SubscriptionBlocked) && sessionVm.SubscriptionBlocked)
            {
                sessionVm.SubscriptionBlocked = false;
                _ = RefreshStatusAsync();
            }
        };
    }

    // 0 = no session cap (unlimited); treat as nil so the banner omits the counter.
    public int? TrialSessionsRemaining =>
        Info is { TrialSessionsUsed: { } used, TrialSessionsLimit: { } limit }
            ? (limit == 0 ? null : Math.Max(0, limit - used))
            : null;

    public int? TrialDaysRemaining
    {
        get
        {
            if (Info?.TrialStart is not { } startStr ||
                Info?.TrialDaysLimit is not { } daysLimit ||
                !DateTimeOffset.TryParse(startStr, out var start))
                return null;

            if (daysLimit == 0) return null;  // 0 = no time cap

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
        OnPropertyChanged(nameof(IsLapsed));
        OnPropertyChanged(nameof(TrialText));
        OnPropertyChanged(nameof(LapsedHeading));
        OnPropertyChanged(nameof(TrialSessionsRemaining));
        OnPropertyChanged(nameof(TrialDaysRemaining));
        OnPropertyChanged(nameof(GraceExpiresAt));
    }
}
