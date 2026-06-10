using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using PabloCompanion.Services;

namespace PabloCompanion.Tests.Services;

/// <summary>
/// Verifies the enrollment payload helpers: the hostname is sent only as a
/// SHA-256 hex digest (never raw), the platform enum is the value the backend
/// expects, and the stable install id is never bundled with the auth tokens that
/// get cleared on sign-out.
/// </summary>
public class DeviceEnrollmentTests
{
    [Fact]
    public void HashHostname_IsLowercaseHexSha256()
    {
        const string hostname = "Therapist-PC";

        var hash = DeviceEnrollment.HashHostname(hostname);

        var expected = Convert.ToHexString(
            SHA256.HashData(Encoding.UTF8.GetBytes(hostname))).ToLowerInvariant();
        Assert.Equal(expected, hash);
        Assert.Equal(64, hash!.Length);
        Assert.Equal(hash.ToLowerInvariant(), hash);
    }

    [Fact]
    public void HashHostname_NeverEqualsRawHostname()
    {
        const string hostname = "Therapist-PC";

        var hash = DeviceEnrollment.HashHostname(hostname);

        Assert.NotEqual(hostname, hash);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public void HashHostname_BlankInput_ReturnsNull(string? hostname)
    {
        Assert.Null(DeviceEnrollment.HashHostname(hostname));
    }

    [Fact]
    public void Platform_IsWindows()
    {
        // Backend Literal is mac|windows|linux — must be exactly "windows".
        Assert.Equal("windows", DeviceEnrollment.Platform);
    }

    [Fact]
    public void InstallId_IsNotClearedOnSignOut()
    {
        // The stable install id must survive sign-out, so it must NOT appear in the
        // private AuthTokenKeys array that ClearAuthTokens() iterates.
        var field = typeof(CredentialManager).GetField(
            "AuthTokenKeys",
            BindingFlags.NonPublic | BindingFlags.Static);
        Assert.NotNull(field);

        var keys = (string[])field!.GetValue(null)!;
        Assert.DoesNotContain("installId", keys);
    }
}
