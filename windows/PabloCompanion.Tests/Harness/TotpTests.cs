using System.Text;
using RecordHarness;

namespace PabloCompanion.Tests.Harness;

/// <summary>
/// Pins the TOTP implementation against the RFC 6238 reference vectors and the
/// e2e suite's otplib defaults (HMAC-SHA1, 6 digits, 30s step).
///
/// A wrong code here doesn't fail loudly — it fails as an opaque Firebase auth
/// rejection, after burning the rate-limited MFA finalize quota.
/// </summary>
public class TotpTests
{
    /// The RFC 6238 Appendix B seed: ASCII "12345678901234567890", base32-encoded.
    private const string RfcSecret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";

    [Theory]
    // RFC 6238 Appendix B (SHA-1 column), truncated to the low 6 digits.
    [InlineData(59L, "287082")]
    [InlineData(1111111109L, "081804")]
    [InlineData(1111111111L, "050471")]
    [InlineData(1234567890L, "005924")]
    [InlineData(2000000000L, "279037")]
    public void Code_MatchesRfc6238Vectors(long unixSeconds, string expected)
    {
        var code = Totp.Code(RfcSecret, DateTimeOffset.FromUnixTimeSeconds(unixSeconds));

        Assert.Equal(expected, code);
    }

    [Fact]
    public void Code_IsAlwaysSixDigits()
    {
        // A code whose leading digit is zero must keep it — trimming would send a
        // 5-character code the server rejects.
        for (long t = 0; t < 3000; t += 30)
        {
            var code = Totp.Code(RfcSecret, DateTimeOffset.FromUnixTimeSeconds(t));
            Assert.Equal(6, code.Length);
            Assert.True(code.All(char.IsAsciiDigit), $"non-digit in '{code}'");
        }
    }

    [Fact]
    public void Code_IsStableWithinAStepAndChangesAcross()
    {
        var early = Totp.Code(RfcSecret, DateTimeOffset.FromUnixTimeSeconds(60));
        var late = Totp.Code(RfcSecret, DateTimeOffset.FromUnixTimeSeconds(89));
        var next = Totp.Code(RfcSecret, DateTimeOffset.FromUnixTimeSeconds(90));

        Assert.Equal(early, late);   // same 30s window
        Assert.NotEqual(early, next); // next window
    }

    [Fact]
    public void Base32Decode_MatchesTheRfcSeed()
    {
        var decoded = Totp.Base32Decode(RfcSecret);

        Assert.Equal("12345678901234567890", Encoding.ASCII.GetString(decoded));
    }

    [Theory]
    [InlineData("gezdgnbvgy3tqojqgezdgnbvgy3tqojq")]     // lower-case
    [InlineData("GEZD GNBV GY3T QOJQ GEZD GNBV GY3T QOJQ")] // spaced, as vaults display it
    [InlineData("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ====")] // padded
    public void Base32Decode_ToleratesSecretFormatting(string secret)
    {
        // The secret is copy-pasted out of a password manager into a GCP secret;
        // it must survive the shapes those tools produce.
        Assert.Equal(Totp.Base32Decode(RfcSecret), Totp.Base32Decode(secret));
    }

    [Fact]
    public void Base32Decode_EmptySecret_YieldsNoBytes()
    {
        Assert.Empty(Totp.Base32Decode(""));
    }
}
