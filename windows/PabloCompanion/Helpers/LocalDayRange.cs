namespace PabloCompanion.Helpers;

/// <summary>
/// The UTC bounds of "today" as the therapist sees it: local midnight to the
/// next local midnight. Using the UTC calendar day instead dropped every US
/// evening appointment (after 20:00 Eastern the UTC date has already rolled
/// over), so the window showed "no upcoming appointments" mid-schedule.
///
/// Takes the clock and zone as arguments so tests can pin both.
/// </summary>
public static class LocalDayRange
{
    public static (DateTime StartUtc, DateTime EndUtc) Today(DateTimeOffset now, TimeZoneInfo zone)
    {
        var localDate = TimeZoneInfo.ConvertTime(now, zone).Date;
        return (ToUtc(localDate, zone), ToUtc(localDate.AddDays(1), zone));
    }

    /// <summary>Today in the machine's own zone.</summary>
    public static (DateTime StartUtc, DateTime EndUtc) Today()
        => Today(DateTimeOffset.UtcNow, TimeZoneInfo.Local);

    private static DateTime ToUtc(DateTime localMidnight, TimeZoneInfo zone)
    {
        var unspecified = DateTime.SpecifyKind(localMidnight, DateTimeKind.Unspecified);
        // A zone whose DST change happens at midnight skips 00:00 on that day;
        // the day then starts at the first instant that exists.
        while (zone.IsInvalidTime(unspecified))
            unspecified = unspecified.AddMinutes(30);
        return TimeZoneInfo.ConvertTimeToUtc(unspecified, zone);
    }
}
