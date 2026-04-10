using PabloCompanion.Helpers;
using PabloCompanion.Models;

namespace PabloCompanion.Tests.Helpers;

public class SessionFormattingTests
{
    private static Session MakeSession(
        string? scheduledAt = null,
        uint? durationMinutes = null,
        PatientSummary? patient = null,
        SessionStatus status = SessionStatus.Scheduled,
        VideoPlatform? videoPlatform = null,
        SessionType? sessionType = null,
        string? notes = null)
    {
        return new Session(
            Id: "sess-1",
            PatientId: "pat-1",
            Patient: patient,
            Status: status,
            ScheduledAt: scheduledAt,
            StartedAt: null,
            EndedAt: null,
            DurationMinutes: durationMinutes,
            VideoLink: null,
            VideoPlatform: videoPlatform,
            SessionType: sessionType,
            Source: SessionSource.Companion,
            Notes: notes,
            CreatedAt: null,
            UpdatedAt: null);
    }

    private static PatientSummary TestPatient => new("pat-1", "Jane", "Doe");

    // --- FormatStatus ---

    [Theory]
    [InlineData(SessionStatus.Scheduled, "Scheduled")]
    [InlineData(SessionStatus.InProgress, "In Progress")]
    [InlineData(SessionStatus.RecordingComplete, "Recorded")]
    [InlineData(SessionStatus.Queued, "Queued")]
    [InlineData(SessionStatus.Processing, "Processing")]
    [InlineData(SessionStatus.PendingReview, "Pending Review")]
    [InlineData(SessionStatus.Finalized, "Finalized")]
    [InlineData(SessionStatus.Cancelled, "Cancelled")]
    [InlineData(SessionStatus.Failed, "Failed")]
    public void FormatStatus_AllStatuses(SessionStatus status, string expected)
    {
        Assert.Equal(expected, SessionFormatting.FormatStatus(status));
    }

    // --- FormatPatientName ---

    [Fact]
    public void FormatPatientName_WithPatient_ReturnsFullName()
    {
        var session = MakeSession(patient: TestPatient);
        Assert.Equal("Jane Doe", SessionFormatting.FormatPatientName(session));
    }

    [Fact]
    public void FormatPatientName_NullPatient_ReturnsUnknown()
    {
        var session = MakeSession(patient: null);
        Assert.Equal("Unknown Patient", SessionFormatting.FormatPatientName(session));
    }

    // --- GetPatientInitials ---

    [Fact]
    public void GetPatientInitials_WithPatient_ReturnsTwoLetters()
    {
        var session = MakeSession(patient: TestPatient);
        Assert.Equal("JD", SessionFormatting.GetPatientInitials(session));
    }

    [Fact]
    public void GetPatientInitials_NullPatient_ReturnsQuestionMark()
    {
        var session = MakeSession(patient: null);
        Assert.Equal("?", SessionFormatting.GetPatientInitials(session));
    }

    // --- FormatTime ---

    [Fact]
    public void FormatTime_WithScheduledAt_ReturnsTimeRange()
    {
        var session = MakeSession(
            scheduledAt: "2025-06-15T14:00:00Z",
            durationMinutes: 50);
        var result = SessionFormatting.FormatTime(session);
        // Should contain AM/PM format with dash separator
        Assert.Contains(" - ", result);
        Assert.Matches(@"\d{1,2}:\d{2} [AP]M", result);
    }

    [Fact]
    public void FormatTime_NullScheduledAt_ReturnsTimeNotSet()
    {
        var session = MakeSession(scheduledAt: null);
        Assert.Equal("Time not set", SessionFormatting.FormatTime(session));
    }

    [Fact]
    public void FormatTime_DefaultDuration_Uses50Min()
    {
        var session = MakeSession(
            scheduledAt: "2025-06-15T14:00:00Z",
            durationMinutes: null);
        var result = SessionFormatting.FormatTime(session);
        // Default 50min — just verify it parses and returns a range
        Assert.Contains(" - ", result);
    }

    // --- FormatTimeShort ---

    [Fact]
    public void FormatTimeShort_WithScheduledAt_ReturnsSingleTime()
    {
        var session = MakeSession(scheduledAt: "2025-06-15T14:00:00Z");
        var result = SessionFormatting.FormatTimeShort(session);
        Assert.Matches(@"\d{1,2}:\d{2} [AP]M", result);
        Assert.DoesNotContain(" - ", result);
    }

    [Fact]
    public void FormatTimeShort_NullScheduledAt_ReturnsEmpty()
    {
        var session = MakeSession(scheduledAt: null);
        Assert.Equal("", SessionFormatting.FormatTimeShort(session));
    }

    // --- FormatDuration ---

    [Fact]
    public void FormatDuration_WithDuration_ReturnsMinutes()
    {
        var session = MakeSession(durationMinutes: 30);
        Assert.Equal("30 min", SessionFormatting.FormatDuration(session));
    }

    [Fact]
    public void FormatDuration_NullDuration_Defaults50()
    {
        var session = MakeSession(durationMinutes: null);
        Assert.Equal("50 min", SessionFormatting.FormatDuration(session));
    }

    // --- FormatDate ---

    [Fact]
    public void FormatDate_Today_ReturnsToday()
    {
        var today = DateTimeOffset.Now.ToString("o");
        var session = MakeSession(scheduledAt: today);
        Assert.Equal("Today", SessionFormatting.FormatDate(session));
    }

    [Fact]
    public void FormatDate_Yesterday_ReturnsYesterday()
    {
        var yesterday = DateTimeOffset.Now.AddDays(-1).ToString("o");
        var session = MakeSession(scheduledAt: yesterday);
        Assert.Equal("Yesterday", SessionFormatting.FormatDate(session));
    }

    [Fact]
    public void FormatDate_OlderDate_ReturnsFormatted()
    {
        var session = MakeSession(scheduledAt: "2024-03-15T10:00:00Z");
        var result = SessionFormatting.FormatDate(session);
        Assert.Contains("2024", result);
        Assert.Contains("Mar", result);
    }

    [Fact]
    public void FormatDate_NullScheduledAt_ReturnsEmpty()
    {
        var session = MakeSession(scheduledAt: null);
        Assert.Equal("", SessionFormatting.FormatDate(session));
    }

    // --- GetPlatformIcon ---

    [Fact]
    public void GetPlatformIcon_Zoom_ReturnsGlyph()
    {
        var session = MakeSession(videoPlatform: VideoPlatform.Zoom);
        Assert.NotEmpty(SessionFormatting.GetPlatformIcon(session));
    }

    [Fact]
    public void GetPlatformIcon_NullPlatform_ReturnsEmpty()
    {
        var session = MakeSession(videoPlatform: null);
        Assert.Equal("", SessionFormatting.GetPlatformIcon(session));
    }

    // --- GetPlatformName ---

    [Fact]
    public void GetPlatformName_Zoom_ReturnsZoom()
    {
        var session = MakeSession(videoPlatform: VideoPlatform.Zoom);
        Assert.Equal("Zoom", SessionFormatting.GetPlatformName(session));
    }

    [Fact]
    public void GetPlatformName_Teams_ReturnsTeams()
    {
        var session = MakeSession(videoPlatform: VideoPlatform.Teams);
        Assert.Equal("Teams", SessionFormatting.GetPlatformName(session));
    }

    [Fact]
    public void GetPlatformName_NullPlatform_ReturnsEmpty()
    {
        var session = MakeSession(videoPlatform: null);
        Assert.Equal("", SessionFormatting.GetPlatformName(session));
    }

    // --- FormatSessionType ---

    [Fact]
    public void FormatSessionType_Individual_ReturnsIndividual()
    {
        var session = MakeSession(sessionType: SessionType.Individual);
        Assert.Equal("Individual", SessionFormatting.FormatSessionType(session));
    }

    [Fact]
    public void FormatSessionType_Null_ReturnsSession()
    {
        var session = MakeSession(sessionType: null);
        Assert.Equal("Session", SessionFormatting.FormatSessionType(session));
    }

    // --- StatusToFilterString ---

    [Theory]
    [InlineData(SessionStatus.Scheduled, "scheduled")]
    [InlineData(SessionStatus.InProgress, "in_progress")]
    [InlineData(SessionStatus.RecordingComplete, "recording_complete")]
    [InlineData(SessionStatus.Finalized, "finalized")]
    [InlineData(SessionStatus.Cancelled, "cancelled")]
    public void StatusToFilterString_MapsCorrectly(SessionStatus status, string expected)
    {
        Assert.Equal(expected, SessionFormatting.StatusToFilterString(status));
    }
}
