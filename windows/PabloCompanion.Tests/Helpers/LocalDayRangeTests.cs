using PabloCompanion.Helpers;

namespace PabloCompanion.Tests.Helpers;

/// <summary>
/// Today's appointments are requested for the therapist's local day. The UTC
/// calendar day rolled over at 20:00 Eastern (EDT) and dropped every evening
/// appointment.
/// </summary>
public class LocalDayRangeTests
{
    private static TimeZoneInfo NewYork()
    {
        try { return TimeZoneInfo.FindSystemTimeZoneById("America/New_York"); }
        catch (TimeZoneNotFoundException) { return TimeZoneInfo.FindSystemTimeZoneById("Eastern Standard Time"); }
    }

    [Fact]
    public void At9pmInNewYorkTodayIsTheLocalDayNotTheUtcDay()
    {
        // 21:00 EDT on 3 Sep is already 01:00 UTC on 4 Sep.
        var now = new DateTimeOffset(2026, 9, 3, 21, 0, 0, TimeSpan.FromHours(-4));

        var (start, end) = LocalDayRange.Today(now, NewYork());

        Assert.Equal(new DateTime(2026, 9, 3, 4, 0, 0, DateTimeKind.Utc), start);
        Assert.Equal(new DateTime(2026, 9, 4, 4, 0, 0, DateTimeKind.Utc), end);
        Assert.Equal(DateTimeKind.Utc, start.Kind);
        Assert.Equal(DateTimeKind.Utc, end.Kind);
    }

    [Fact]
    public void AnEveningAppointmentFallsInsideTheRange()
    {
        var now = new DateTimeOffset(2026, 9, 3, 21, 0, 0, TimeSpan.FromHours(-4));
        var (start, end) = LocalDayRange.Today(now, NewYork());

        // 21:30 EDT appointment = 01:30 UTC next day.
        var appointment = new DateTime(2026, 9, 4, 1, 30, 0, DateTimeKind.Utc);
        Assert.True(appointment >= start && appointment < end);
    }

    [Fact]
    public void TheDayAcrossTheFallBackChangeIsTwentyFiveHours()
    {
        // US DST ends 1 Nov 2026: midnight-to-midnight is 25 hours that day.
        var now = new DateTimeOffset(2026, 11, 1, 12, 0, 0, TimeSpan.FromHours(-5));

        var (start, end) = LocalDayRange.Today(now, NewYork());

        Assert.Equal(new DateTime(2026, 11, 1, 4, 0, 0, DateTimeKind.Utc), start);
        Assert.Equal(new DateTime(2026, 11, 2, 5, 0, 0, DateTimeKind.Utc), end);
    }

    [Fact]
    public void UtcZoneMatchesTheUtcDay()
    {
        var now = new DateTimeOffset(2026, 9, 3, 23, 59, 0, TimeSpan.Zero);

        var (start, end) = LocalDayRange.Today(now, TimeZoneInfo.Utc);

        Assert.Equal(new DateTime(2026, 9, 3, 0, 0, 0, DateTimeKind.Utc), start);
        Assert.Equal(new DateTime(2026, 9, 4, 0, 0, 0, DateTimeKind.Utc), end);
    }
}
