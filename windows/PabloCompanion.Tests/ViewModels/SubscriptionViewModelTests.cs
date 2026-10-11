using PabloCompanion.Models;
using PabloCompanion.ViewModels;
using PabloCompanion.Services;

namespace PabloCompanion.Tests.ViewModels;

/// <summary>
/// Verifies the 0=unlimited convention for trial_sessions_limit and trial_days_limit.
/// Backend contract: a limit of 0 means no cap — the UI must not show "0 remaining".
/// </summary>
public sealed class SubscriptionViewModelTests
{
    // --- TrialSessionsRemaining ---

    [Fact]
    public void TrialSessionsRemaining_NormalLimit_ReturnsRemainder()
    {
        var vm = MakeVm(sessionsUsed: 8, sessionsLimit: 20);
        Assert.Equal(12, vm.TrialSessionsRemaining);
    }

    [Fact]
    public void TrialSessionsRemaining_ZeroLimit_ReturnsNull()
    {
        // trial_sessions_limit=0 means unlimited — must not produce "0 sessions remaining".
        var vm = MakeVm(sessionsUsed: 5, sessionsLimit: 0);
        Assert.Null(vm.TrialSessionsRemaining);
    }

    [Fact]
    public void TrialSessionsRemaining_NullLimit_ReturnsNull()
    {
        var vm = MakeVm(sessionsUsed: 3, sessionsLimit: null);
        Assert.Null(vm.TrialSessionsRemaining);
    }

    [Fact]
    public void TrialSessionsRemaining_UsedExceedsLimit_ClampsToZero()
    {
        var vm = MakeVm(sessionsUsed: 25, sessionsLimit: 20);
        Assert.Equal(0, vm.TrialSessionsRemaining);
    }

    // --- TrialDaysRemaining ---

    [Fact]
    public void TrialDaysRemaining_NormalLimit_ReturnsApproxRemainder()
    {
        var start = DateTimeOffset.UtcNow.AddDays(-10).ToString("O");
        var vm = MakeVm(daysLimit: 30, trialStart: start);
        var remaining = vm.TrialDaysRemaining;
        Assert.NotNull(remaining);
        Assert.InRange(remaining!.Value, 19, 20);
    }

    [Fact]
    public void TrialDaysRemaining_ZeroLimit_ReturnsNull()
    {
        // trial_days_limit=0 means unlimited — must not produce "0 days left".
        var start = DateTimeOffset.UtcNow.AddDays(-10).ToString("O");
        var vm = MakeVm(daysLimit: 0, trialStart: start);
        Assert.Null(vm.TrialDaysRemaining);
    }

    [Fact]
    public void TrialDaysRemaining_NullLimit_ReturnsNull()
    {
        var start = DateTimeOffset.UtcNow.AddDays(-5).ToString("O");
        var vm = MakeVm(daysLimit: null, trialStart: start);
        Assert.Null(vm.TrialDaysRemaining);
    }

    // --- BannerKind ---

    [Theory]
    [InlineData("active", "hidden")]
    [InlineData("trial", "trial")]
    [InlineData("trial_expired", "trial_expired")]
    [InlineData("past_due", "past_due")]
    [InlineData("canceled", "canceled")]
    [InlineData("paused", "subscription_needed")]
    [InlineData("", "subscription_needed")]
    public void BannerKind_MapsEachStatus(string status, string expected)
    {
        var vm = MakeVm(status: status);
        Assert.Equal(expected, vm.BannerKind);
    }

    [Fact]
    public void BannerKind_NoInfo_IsHidden()
    {
        var vm = new SubscriptionViewModel(null!);
        Assert.Equal("hidden", vm.BannerKind);
        Assert.False(vm.ShouldShowBanner);
    }

    [Theory]
    [InlineData("active")]
    [InlineData("canceled")]
    [InlineData("trial_expired")]
    public void BannerKind_UnexpiredGrace_IsGraceActive(string status)
    {
        // A grace extension reports the status as active server-side; either way
        // an unexpired grace window shows the "you're covered" banner.
        var vm = MakeVm(status: status,
            graceExpiresAt: DateTimeOffset.UtcNow.AddHours(12).ToString("O"));
        Assert.Equal("grace_active", vm.BannerKind);
        Assert.False(vm.IsLapsed);
    }

    [Fact]
    public void BannerKind_ExpiredGrace_FallsBackToStatus()
    {
        var vm = MakeVm(status: "trial_expired",
            graceExpiresAt: DateTimeOffset.UtcNow.AddHours(-1).ToString("O"));
        Assert.Equal("trial_expired", vm.BannerKind);
    }

    [Theory]
    [InlineData("trial_expired", true)]
    [InlineData("past_due", true)]
    [InlineData("canceled", true)]
    [InlineData("paused", true)]
    [InlineData("trial", false)]
    [InlineData("active", false)]
    public void IsLapsed_CoversEveryStateThatBlocksSessions(string status, bool expected)
    {
        Assert.Equal(expected, MakeVm(status: status).IsLapsed);
        Assert.Equal(expected, MakeVm(status: status).LapsedHeading != null);
    }

    // --- Copy ---

    [Theory]
    [InlineData("trial_expired", "Your free trial has ended. Subscribe to keep recording sessions.")]
    [InlineData("canceled", "Your subscription has ended. Resubscribe to keep recording sessions.")]
    [InlineData("past_due", "Your payment needs attention")]
    [InlineData("paused", "Subscribe to keep recording sessions.")]
    public void LapsedHeading_PerState(string status, string expected)
    {
        Assert.Equal(expected, MakeVm(status: status).LapsedHeading);
    }

    [Fact]
    public void TrialText_NoLimits_SaysFreeTrial()
    {
        Assert.Equal("You're on a free trial", MakeVm().TrialText);
    }

    [Fact]
    public void TrialText_SessionsOnly()
    {
        Assert.Equal("Free trial \u2014 12 sessions remaining",
            MakeVm(sessionsUsed: 8, sessionsLimit: 20).TrialText);
    }

    [Fact]
    public void TrialText_OneSession_IsSingular()
    {
        Assert.Equal("Free trial \u2014 1 session remaining",
            MakeVm(sessionsUsed: 19, sessionsLimit: 20).TrialText);
    }

    [Fact]
    public void TrialText_SessionsAndDays()
    {
        var start = DateTimeOffset.UtcNow.AddDays(-10).AddHours(-1).ToString("O");
        Assert.Equal("Free trial \u2014 12 sessions remaining, 20 days left",
            MakeVm(sessionsUsed: 8, sessionsLimit: 20, daysLimit: 30, trialStart: start).TrialText);
    }

    [Fact]
    public void TrialText_UnlimitedSessions_ShowsDaysOnly()
    {
        var start = DateTimeOffset.UtcNow.AddDays(-29).AddHours(-1).ToString("O");
        Assert.Equal("Free trial \u2014 1 day left",
            MakeVm(sessionsUsed: 5, sessionsLimit: 0, daysLimit: 30, trialStart: start).TrialText);
    }

    // --- Billing link ---

    [Fact]
    public void ManageSubscriptionUrl_DefaultsToTheHostedBillingPage()
    {
        var vm = new SubscriptionViewModel(null!);
        Assert.Equal(new Uri("https://app.pablo.health/dashboard/billing"), vm.ManageSubscriptionUrl);
    }

    [Fact]
    public void StartBlockedMessage_IsTheSubscribeCopy()
    {
        Assert.Equal("Subscribe to start sessions.", SubscriptionViewModel.StartBlockedMessage);
    }

    // --- Helpers ---

    private static SubscriptionViewModel MakeVm(
        int? sessionsUsed = null,
        int? sessionsLimit = null,
        int? daysLimit = null,
        string? trialStart = null,
        string status = "trial",
        string? graceExpiresAt = null)
    {
        var vm = new SubscriptionViewModel(null!);
        vm.Info = new SubscriptionInfo(
            Status: status,
            Plan: "solo",
            TrialSessionsUsed: sessionsUsed,
            TrialSessionsLimit: sessionsLimit,
            TrialDaysLimit: daysLimit,
            TrialStart: trialStart,
            GraceExtensionAvailable: false,
            GraceExtensionExpiresAt: graceExpiresAt);
        return vm;
    }
}
