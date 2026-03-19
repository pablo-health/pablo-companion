using PabloCompanion.Services;

namespace PabloCompanion.Tests.Services;

public class JwtDecoderTests
{
    // Test JWT: header.payload.signature
    // Payload: {"email":"test@pablo.health","exp":1735689600}
    private const string TestJwt = "eyJhbGciOiJSUzI1NiJ9.eyJlbWFpbCI6InRlc3RAcGFibG8uaGVhbHRoIiwiZXhwIjoxNzM1Njg5NjAwfQ.signature";

    [Fact]
    public void GetEmail_ReturnsEmail()
    {
        var email = JwtDecoder.GetEmail(TestJwt);
        Assert.Equal("test@pablo.health", email);
    }

    [Fact]
    public void GetExpiry_ReturnsExpiry()
    {
        var expiry = JwtDecoder.GetExpiry(TestJwt);
        Assert.NotNull(expiry);
        Assert.Equal(2025, expiry.Value.Year);
    }

    [Fact]
    public void GetEmail_InvalidJwt_ReturnsNull()
    {
        Assert.Null(JwtDecoder.GetEmail("not-a-jwt"));
    }

    [Fact]
    public void GetExpiry_InvalidJwt_ReturnsNull()
    {
        Assert.Null(JwtDecoder.GetExpiry(""));
    }
}
