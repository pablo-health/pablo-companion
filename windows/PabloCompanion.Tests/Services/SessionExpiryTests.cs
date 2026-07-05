using PabloCompanion.Services;
using PabloCompanion.ViewModels;

namespace PabloCompanion.Tests.Services;

/// <summary>
/// Covers the server-side session-expiry plumbing: parsing the backend's
/// structured error envelope (including the idle-timeout code carried on
/// 401s) and the distinct user-facing messaging it drives.
/// </summary>
public sealed class SessionExpiryTests
{
    [Fact]
    public void ErrorEnvelope_ParsesIdleTimeoutCode()
    {
        var body = """{"error": {"code": "IDLE_TIMEOUT", "message": "Session expired"}}""";

        var (message, code) = APIClient.TryParseErrorEnvelope(body);

        Assert.Equal(APIClient.IdleTimeoutCode, code);
        Assert.Equal("Session expired", message);
    }

    [Theory]
    [InlineData("")]
    [InlineData("Unauthorized")]
    [InlineData("{\"detail\": \"no envelope here\"}")]
    [InlineData("[1, 2, 3]")]
    public void ErrorEnvelope_ReturnsNullCodeForNonEnvelopeBodies(string body)
    {
        var (_, code) = APIClient.TryParseErrorEnvelope(body);

        Assert.Null(code);
    }

    [Fact]
    public void SessionRejectedMessage_IdleTimeoutIsDistinctFromGeneric()
    {
        var idle = AuthViewModel.SessionRejectedMessage(APIClient.IdleTimeoutCode);
        var generic = AuthViewModel.SessionRejectedMessage(null);

        Assert.NotEqual(idle, generic);
        Assert.Contains("inactivity", idle, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("sign in", idle, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("sign in", generic, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void SessionRejectedMessage_OtherCodesGetGenericMessage()
    {
        Assert.Equal(
            AuthViewModel.SessionRejectedMessage(null),
            AuthViewModel.SessionRejectedMessage("UNAUTHENTICATED"));
    }
}
