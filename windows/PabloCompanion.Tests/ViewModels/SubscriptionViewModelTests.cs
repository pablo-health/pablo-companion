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

    // --- Helpers ---

    private static SubscriptionViewModel MakeVm(
        int? sessionsUsed = null,
        int? sessionsLimit = null,
        int? daysLimit = null,
        string? trialStart = null)
    {
        var vm = new SubscriptionViewModel(null!);
        vm.Info = new SubscriptionInfo(
            Status: "trial",
            Plan: "solo",
            TrialSessionsUsed: sessionsUsed,
            TrialSessionsLimit: sessionsLimit,
            TrialDaysLimit: daysLimit,
            TrialStart: trialStart,
            GraceExtensionAvailable: false,
            GraceExtensionExpiresAt: null);
        return vm;
    }
}
