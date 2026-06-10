using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using PabloCompanion.Services;

namespace PabloCompanion.Tests.Services;

/// <summary>
/// Pins the DPoP proof wire format against pablo's <c>backend/app/middleware/dpop.py</c>:
/// the header pins <c>alg=ES256</c>, the claims are <c>htm/htu/iat/jti</c> with the
/// query stripped from <c>htu</c>, the signature is JOSE raw <c>r||s</c> (64 bytes, not
/// ASN.1/DER), and every proof carries a fresh <c>jti</c>. A drift in any of these
/// 401s every authenticated request once the server enforces proofs.
/// </summary>
public class DpopProofTests
{
    private static ECDsa NewKey() => ECDsa.Create(ECCurve.NamedCurves.nistP256);

    private static (string Header, JsonElement Claims, byte[] Signature) Decompose(string jws)
    {
        var parts = jws.Split('.');
        Assert.Equal(3, parts.Length);

        var header = Encoding.UTF8.GetString(Base64UrlDecode(parts[0]));
        using var claimsDoc = JsonDocument.Parse(Base64UrlDecode(parts[1]));
        return (header, claimsDoc.RootElement.Clone(), Base64UrlDecode(parts[2]));
    }

    private static byte[] Base64UrlDecode(string value)
    {
        var s = value.Replace('-', '+').Replace('_', '/');
        s = (s.Length % 4) switch { 2 => s + "==", 3 => s + "=", _ => s };
        return Convert.FromBase64String(s);
    }

    [Fact]
    public void Create_Header_PinsEs256AndDpopType()
    {
        using var key = NewKey();
        var (header, _, _) = Decompose(DpopProof.Create(key, "GET", "https://api.pablo.health/api/health"));

        using var doc = JsonDocument.Parse(header);
        Assert.Equal("dpop+jwt", doc.RootElement.GetProperty("typ").GetString());
        Assert.Equal("ES256", doc.RootElement.GetProperty("alg").GetString());
    }

    [Fact]
    public void Create_Claims_HaveRequiredFields()
    {
        using var key = NewKey();
        var before = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var (_, claims, _) = Decompose(DpopProof.Create(key, "post", "https://api.pablo.health/api/launch/redeem"));
        var after = DateTimeOffset.UtcNow.ToUnixTimeSeconds();

        // htm is uppercased regardless of caller casing.
        Assert.Equal("POST", claims.GetProperty("htm").GetString());
        Assert.Equal("https://api.pablo.health/api/launch/redeem", claims.GetProperty("htu").GetString());

        var iat = claims.GetProperty("iat").GetInt64();
        Assert.InRange(iat, before, after);

        Assert.False(string.IsNullOrEmpty(claims.GetProperty("jti").GetString()));
    }

    [Theory]
    [InlineData("https://api.pablo.health/api/sessions?page=1&page_size=20", "https://api.pablo.health/api/sessions")]
    [InlineData("https://api.pablo.health/api/sessions/abc?x=1#frag", "https://api.pablo.health/api/sessions/abc")]
    [InlineData("https://api.pablo.health/api/health", "https://api.pablo.health/api/health")]
    public void Create_Htu_StripsQueryAndFragment(string url, string expectedHtu)
    {
        using var key = NewKey();
        var (_, claims, _) = Decompose(DpopProof.Create(key, "GET", url));

        Assert.Equal(expectedHtu, claims.GetProperty("htu").GetString());
    }

    [Fact]
    public void Create_Htu_DropsDefaultHttpsPort()
    {
        using var key = NewKey();
        var (_, claims, _) = Decompose(
            DpopProof.Create(key, "GET", "https://api.pablo.health:443/api/health"));

        // urlunsplit on the server side drops the default port; the client must match.
        Assert.Equal("https://api.pablo.health/api/health", claims.GetProperty("htu").GetString());
    }

    [Fact]
    public void Create_Signature_IsRaw64ByteConcat_NotDer()
    {
        using var key = NewKey();
        var (_, _, signature) = Decompose(DpopProof.Create(key, "GET", "https://api.pablo.health/api/health"));

        // P-256 r||s is exactly 64 bytes. A DER/ASN.1 ECDSA signature starts with the
        // 0x30 SEQUENCE tag and is ~70-72 bytes — guard against accidentally emitting it.
        Assert.Equal(64, signature.Length);
        Assert.NotEqual(0x30, signature[0]);
    }

    [Fact]
    public void Create_Signature_VerifiesAgainstPublicKey_WithIeeeP1363()
    {
        using var key = NewKey();
        var jws = DpopProof.Create(key, "GET", "https://api.pablo.health/api/health");
        var parts = jws.Split('.');
        var signingInput = Encoding.ASCII.GetBytes($"{parts[0]}.{parts[1]}");
        var signature = Base64UrlDecode(parts[2]);

        // Verifies only when interpreted as raw r||s (the format PyJWT's ES256 uses).
        Assert.True(key.VerifyData(
            signingInput, signature, HashAlgorithmName.SHA256,
            DSASignatureFormat.IeeeP1363FixedFieldConcatenation));
    }

    [Fact]
    public void Create_Jti_IsUniquePerCall()
    {
        using var key = NewKey();
        var jtis = new HashSet<string>();
        for (var i = 0; i < 200; i++)
        {
            var (_, claims, _) = Decompose(DpopProof.Create(key, "GET", "https://api.pablo.health/api/health"));
            Assert.True(jtis.Add(claims.GetProperty("jti").GetString()!), "jti was reused across proofs");
        }
    }
}
