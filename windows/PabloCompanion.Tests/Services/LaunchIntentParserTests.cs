using PabloCompanion.Services;

namespace PabloCompanion.Tests.Services;

/// <summary>
/// Covers the dispatch rules for the two companion deep-link entry points:
/// domain-verified <c>https://&lt;host&gt;/launch/&lt;intent_id&gt;</c> links and the
/// legacy <c>pablohealth://session/start</c> scheme. The contract rule under test:
/// an <c>intent</c> always wins (redeemed) and an <c>appointment</c> param is only
/// honored when no intent is present.
/// </summary>
public class LaunchIntentParserTests
{
    [Theory]
    [InlineData("https://app.pablo.health/launch/abc123", "abc123")]
    [InlineData("https://dev.pablo.health/launch/abc123", "abc123")]
    [InlineData("https://app.pablo.health/launch/AbC-_9xZ", "AbC-_9xZ")]
    public void Parse_VerifiedLaunchLink_BothHosts_ReturnsIntent(string url, string expectedId)
    {
        var link = LaunchIntentParser.Parse(new Uri(url));

        Assert.Equal(LaunchLinkKind.Intent, link.Kind);
        Assert.Equal(expectedId, link.Value);
    }

    [Fact]
    public void Parse_VerifiedLink_PercentEncodedSegment_IsDecoded()
    {
        // %2D is '-'. We accept the decoded form; the redeem call escapes again.
        var link = LaunchIntentParser.Parse(new Uri("https://app.pablo.health/launch/a%2Db"));

        Assert.Equal(LaunchLinkKind.Intent, link.Kind);
        Assert.Equal("a-b", link.Value);
    }

    [Theory]
    [InlineData("https://evil.example.com/launch/abc123")]
    [InlineData("https://pablo.health/launch/abc123")]
    [InlineData("https://app.pablo.health/launch/")]
    [InlineData("https://app.pablo.health/launch/a/b")]
    [InlineData("https://app.pablo.health/other/abc123")]
    [InlineData("https://app.pablo.health/")]
    public void Parse_NonMatchingHttpsLinks_ReturnsNone(string url)
    {
        var link = LaunchIntentParser.Parse(new Uri(url));

        Assert.Equal(LaunchLinkKind.None, link.Kind);
        Assert.Null(link.Value);
    }

    [Fact]
    public void Parse_LegacyScheme_WithIntent_ReturnsIntent()
    {
        var link = LaunchIntentParser.Parse(
            new Uri("pablohealth://session/start?intent=xyz789"));

        Assert.Equal(LaunchLinkKind.Intent, link.Kind);
        Assert.Equal("xyz789", link.Value);
    }

    [Fact]
    public void Parse_LegacyScheme_IntentWinsOverAppointment()
    {
        // Intent present alongside appointment: intent wins, appointment ignored.
        var link = LaunchIntentParser.Parse(
            new Uri("pablohealth://session/start?appointment=appt-1&intent=xyz789"));

        Assert.Equal(LaunchLinkKind.Intent, link.Kind);
        Assert.Equal("xyz789", link.Value);
    }

    [Fact]
    public void Parse_LegacyScheme_AppointmentOnly_ReturnsLegacyAppointment()
    {
        var link = LaunchIntentParser.Parse(
            new Uri("pablohealth://session/start?appointment=appt-1"));

        Assert.Equal(LaunchLinkKind.LegacyAppointment, link.Kind);
        Assert.Equal("appt-1", link.Value);
    }

    [Theory]
    [InlineData("pablohealth://session/start")]
    [InlineData("pablohealth://session/start?intent=")]
    [InlineData("pablohealth://session/start?appointment=")]
    [InlineData("pablohealth://session/other?intent=x")]
    [InlineData("pablohealth://callback?code=abc&state=def")]
    [InlineData("pablohealth://patient/123")]
    public void Parse_LegacyScheme_NonStartOrEmpty_ReturnsNone(string url)
    {
        var link = LaunchIntentParser.Parse(new Uri(url));

        Assert.Equal(LaunchLinkKind.None, link.Kind);
    }

    [Fact]
    public void Parse_Null_ReturnsNone()
    {
        var link = LaunchIntentParser.Parse(null);

        Assert.Equal(LaunchLinkKind.None, link.Kind);
        Assert.Null(link.Value);
    }
}
