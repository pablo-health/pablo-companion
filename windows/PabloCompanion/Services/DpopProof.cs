using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace PabloCompanion.Services;

/// <summary>
/// Builds a DPoP proof JWS (RFC 9449 §4) for a single backend request, signed by
/// the install's P-256 device key. The proof is bound to the request method and
/// URL and is single-use (fresh <c>jti</c> per call).
///
/// The matching server check lives in pablo's <c>backend/app/middleware/dpop.py</c>:
/// it pins <c>alg=ES256</c>, requires <c>htm/htu/iat/jti</c>, compares <c>htu</c>
/// against the request scheme+host+path with the query and fragment stripped, and
/// rejects a proof whose <c>iat</c> is more than ±60s from server time. We keep the
/// claim shape and the signature encoding (JOSE raw r||s, not ASN.1/DER) in lockstep
/// with that middleware — see <c>docs/design/companion-dpop-binding.md</c>.
/// </summary>
public static class DpopProof
{
    private const string Header = """{"typ":"dpop+jwt","alg":"ES256"}""";

    /// <summary>
    /// Returns the canonical <c>htu</c> for a request URL: scheme + host + path with
    /// the query string and fragment removed (RFC 9449 §4.3, mirrored by the server's
    /// <c>_canonical_htu</c>). A default port is dropped so the value matches the host
    /// header the server reconstructs.
    /// </summary>
    public static string CanonicalHtu(string url)
    {
        var uri = new Uri(url);
        // GetLeftPart(Path) keeps scheme://host[:port]/path and drops ?query#fragment.
        // Uri normalizes away the default port for the scheme, so https on 443 yields
        // no explicit port — matching the server's urlunsplit reconstruction.
        return uri.GetLeftPart(UriPartial.Path);
    }

    /// <summary>
    /// Builds and signs a compact-serialized DPoP proof for <paramref name="method"/>
    /// + <paramref name="url"/> using <paramref name="signingKey"/> (an ES256 / P-256
    /// key). <paramref name="url"/> may carry a query string; it is stripped from the
    /// <c>htu</c> claim. The signature is JOSE raw <c>r||s</c> (64 bytes), base64url
    /// without padding — never ASN.1/DER.
    /// </summary>
    public static string Create(
        ECDsa signingKey,
        string method,
        string url,
        DateTimeOffset? now = null)
    {
        var iat = (now ?? DateTimeOffset.UtcNow).ToUnixTimeSeconds();

        var claims = new Dictionary<string, object>
        {
            ["htm"] = method.ToUpperInvariant(),
            ["htu"] = CanonicalHtu(url),
            ["iat"] = iat,
            ["jti"] = Guid.NewGuid().ToString("N"),
        };

        var encodedHeader = Base64Url(Encoding.UTF8.GetBytes(Header));
        var encodedClaims = Base64Url(JsonSerializer.SerializeToUtf8Bytes(claims));
        var signingInput = $"{encodedHeader}.{encodedClaims}";

        // IeeeP1363FixedFieldConcatenation gives the JOSE raw r||s (64 bytes for P-256)
        // the server's PyJWT ES256 verifier expects. The default SignData format is
        // ASN.1/DER, which would fail verification — be explicit here.
        var signature = signingKey.SignData(
            Encoding.ASCII.GetBytes(signingInput),
            HashAlgorithmName.SHA256,
            DSASignatureFormat.IeeeP1363FixedFieldConcatenation);

        return $"{signingInput}.{Base64Url(signature)}";
    }

    private static string Base64Url(byte[] bytes)
        => Convert.ToBase64String(bytes).Replace('+', '-').Replace('/', '_').TrimEnd('=');
}
