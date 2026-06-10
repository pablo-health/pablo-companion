using PabloCompanion.Services;

namespace PabloCompanion.Tests.Services;

/// <summary>
/// Covers the deep-link dispatch decision (<see cref="LaunchIntentParser.Route"/>):
/// an intent link redeems; a legacy appointment-only link is no longer trusted to
/// start a session from a raw appointment id, so it resolves to ShowExpired with no
/// id — i.e. no network fetch. The OAuth callback and unknown links are ignored.
/// </summary>
public class LaunchRouteTests
{
    [Theory]
    [InlineData("https://app.pablo.health/launch/abc123", "abc123")]
    [InlineData("pablohealth://session/start?intent=xyz789", "xyz789")]
    [InlineData("pablohealth://session/start?appointment=appt-1&intent=xyz789", "xyz789")]
    public void Route_IntentLink_Redeems(string url, string expectedIntentId)
    {
        var (action, intentId) = LaunchIntentParser.Route(new Uri(url));

        Assert.Equal(LaunchAction.Redeem, action);
        Assert.Equal(expectedIntentId, intentId);
    }

    [Fact]
    public void Route_AppointmentOnly_ShowsExpired_AndCarriesNoId()
    {
        // The legacy appointment-only path must NOT redeem or fetch — the router shows
        // the soft expired notice instead. No id flows through, so nothing can be
        // fetched from it.
        var (action, intentId) = LaunchIntentParser.Route(
            new Uri("pablohealth://session/start?appointment=appt-1"));

        Assert.Equal(LaunchAction.ShowExpired, action);
        Assert.Null(intentId);
    }

    [Theory]
    [InlineData("pablohealth://callback?code=abc&state=def")] // OAuth route — untouched
    [InlineData("pablohealth://session/start")]
    [InlineData("https://evil.example.com/launch/abc123")]
    [InlineData("pablohealth://patient/123")]
    public void Route_NonHandoffOrOAuth_Ignored(string url)
    {
        var (action, intentId) = LaunchIntentParser.Route(new Uri(url));

        Assert.Equal(LaunchAction.Ignore, action);
        Assert.Null(intentId);
    }

    [Fact]
    public void Route_Null_Ignored()
    {
        var (action, intentId) = LaunchIntentParser.Route(null);

        Assert.Equal(LaunchAction.Ignore, action);
        Assert.Null(intentId);
    }
}
