using PabloCompanion.Services;

namespace PabloCompanion.Tests.Services;

public class UrlValidatorTests
{
    [Fact]
    public void ValidateScheme_HttpsUrl_ReturnsNull()
    {
        Assert.Null(UrlValidator.ValidateScheme("https://api.pablo.health"));
    }

    [Fact]
    public void ValidateScheme_HttpUrl_ReturnsError()
    {
        // In non-debug builds, plain HTTP should fail (unless localhost)
        var result = UrlValidator.ValidateScheme("http://evil.com");
        // In debug mode, this will also fail (non-localhost)
        Assert.NotNull(result);
    }

    [Fact]
    public void ThrowIfInvalid_HttpUrl_Throws()
    {
        Assert.Throws<UriFormatException>(() =>
            UrlValidator.ThrowIfInvalid("http://evil.com"));
    }

    [Theory]
    [InlineData("https://example.com/dashboard", "https://example.com")]
    [InlineData("https://example.com/dashboard/settings", "https://example.com")]
    [InlineData("https://example.com", "https://example.com")]
    [InlineData("https://example.com/", "https://example.com")]
    [InlineData("https://example.com:8080/path", "https://example.com:8080")]
    public void NormalizeToOrigin_StripsPath(string input, string expected)
    {
        Assert.Equal(expected, UrlValidator.NormalizeToOrigin(input));
    }

    [Fact]
    public void NormalizeToOrigin_InvalidUrl_ReturnsTrimmed()
    {
        Assert.Equal("not-a-url", UrlValidator.NormalizeToOrigin("not-a-url/"));
    }
}
