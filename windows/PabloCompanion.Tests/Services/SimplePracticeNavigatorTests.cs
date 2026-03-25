using PabloCompanion.Services;

namespace PabloCompanion.Tests.Services;

public class SimplePracticeNavigatorTests
{
    [Theory]
    [InlineData("2026-03-23T20:00:00Z", "8:00 PM")]
    [InlineData("2026-03-23T08:30:00Z", "8:30 AM")]
    [InlineData("2026-03-23T12:00:00Z", "12:00 PM")]
    [InlineData("2026-03-23T00:00:00Z", "12:00 AM")]
    public void FormatDisplayTime_ConvertsIsoToDisplayFormat(string iso, string expected)
    {
        var result = SimplePracticeNavigator.FormatDisplayTime(iso);
        // Compare ignoring locale differences in AM/PM casing
        Assert.Equal(expected.ToUpperInvariant(), result.ToUpperInvariant());
    }

    [Fact]
    public void FormatDisplayTime_ReturnsEmptyForInvalidInput()
    {
        var result = SimplePracticeNavigator.FormatDisplayTime("not-a-date");
        Assert.Equal("", result);
    }

    [Fact]
    public void FormatDisplayTime_ReturnsEmptyForEmptyInput()
    {
        var result = SimplePracticeNavigator.FormatDisplayTime("");
        Assert.Equal("", result);
    }
}
