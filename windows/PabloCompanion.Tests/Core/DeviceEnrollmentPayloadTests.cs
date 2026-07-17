using System.Security.Cryptography;
using System.Text.Json;
using PabloCompanion.Core;

namespace PabloCompanion.Tests.Core;

/// <summary>
/// Pins the enrollment payload against the backend's <c>CompanionEnrollment</c>
/// model (<c>backend/app/models/companion_device.py</c>):
///
///   install_id            str, 8..64
///   platform              Literal["mac", "windows", "linux"]
///   os_version            str | None, max 64
///   hostname_hash         str | None, max 64
///   device_public_key_jwk dict[str, str]
///   key_storage           Literal["hardware", "software"]
///
/// The JWK and key_storage are required with no defaults, so a partial or
/// out-of-enum payload 422s the entire OAuth exchange before the handler runs —
/// i.e. it breaks sign-in, not just enrollment.
/// </summary>
public class DeviceEnrollmentPayloadTests
{
    private static Dictionary<string, object?> BuildWithEphemeralKey(string installId = "install-abcdef123456")
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        return DeviceEnrollment.BuildPayload(
            installId, DeviceEnrollment.PublicJwk(key), DeviceEnrollment.SoftwareKeyStorage);
    }

    [Fact]
    public void Payload_UsesTheEnumValuesTheBackendAccepts()
    {
        var payload = BuildWithEphemeralKey();

        Assert.Equal("windows", payload["platform"]);
        Assert.Equal("software", payload["key_storage"]);
    }

    [Fact]
    public void Payload_CarriesEverySchemaRequiredField()
    {
        var payload = BuildWithEphemeralKey();

        foreach (var field in new[]
                 {
                     "install_id", "platform", "os_version", "hostname_hash",
                     "device_public_key_jwk", "key_storage",
                 })
        {
            Assert.True(payload.ContainsKey(field), $"payload is missing {field}");
        }
    }

    [Fact]
    public void HostnameHash_FitsTheSixtyFourCharColumn()
    {
        // SHA-256 hex is exactly 64 chars and the backend's cap is 64 — no headroom,
        // so any change to the digest or its encoding overflows the field.
        var hash = DeviceEnrollment.HashHostname("some-machine-name");

        Assert.NotNull(hash);
        Assert.Equal(64, hash!.Length);
        Assert.True(hash.All(char.IsAsciiHexDigitLower), "hash should be lowercase hex");
    }

    [Fact]
    public void OsVersion_FitsTheSixtyFourCharCap()
    {
        var payload = BuildWithEphemeralKey();

        var osVersion = Assert.IsType<string>(payload["os_version"]);
        Assert.InRange(osVersion.Length, 1, 64);
    }

    [Fact]
    public void InstallId_FitsTheEightToSixtyFourRange()
    {
        // The harness mints a lowercase GUID per run; the app persists one. Both
        // must land inside the backend's Field(min_length=8, max_length=64).
        var installId = Guid.NewGuid().ToString().ToLowerInvariant();
        var payload = BuildWithEphemeralKey(installId);

        var sent = Assert.IsType<string>(payload["install_id"]);
        Assert.InRange(sent.Length, 8, 64);
    }

    [Fact]
    public void PublicJwk_IsAFlatStringMapMatchingDictStrStr()
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);

        var jwk = DeviceEnrollment.PublicJwk(key);

        Assert.Equal("EC", jwk["kty"]);
        Assert.Equal("P-256", jwk["crv"]);
        // P-256 field elements are 32 bytes → 43 base64url chars, unpadded.
        Assert.Equal(43, jwk["x"].Length);
        Assert.Equal(43, jwk["y"].Length);
        foreach (var value in jwk.Values)
            Assert.DoesNotContain('=', value);
    }

    [Fact]
    public void PublicJwk_RoundTripsThroughJsonAsStrings()
    {
        // dict[str, str] on the backend: every value must serialize as a JSON
        // string, never a number or nested object.
        var payload = BuildWithEphemeralKey();

        var json = JsonSerializer.Serialize(payload);
        using var doc = JsonDocument.Parse(json);
        var jwk = doc.RootElement.GetProperty("device_public_key_jwk");

        Assert.Equal(JsonValueKind.Object, jwk.ValueKind);
        foreach (var property in jwk.EnumerateObject())
            Assert.Equal(JsonValueKind.String, property.Value.ValueKind);
    }

    [Fact]
    public void PublicJwk_IsStableForTheSameKeyAndDistinctAcrossKeys()
    {
        using var first = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        using var second = ECDsa.Create(ECCurve.NamedCurves.nistP256);

        Assert.Equal(DeviceEnrollment.PublicJwk(first), DeviceEnrollment.PublicJwk(first));
        Assert.NotEqual(DeviceEnrollment.PublicJwk(first)["x"], DeviceEnrollment.PublicJwk(second)["x"]);
    }

    [Fact]
    public void BuildPayload_RejectsABlankInstallId()
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);

        Assert.Throws<ArgumentException>(() => DeviceEnrollment.BuildPayload(
            "  ", DeviceEnrollment.PublicJwk(key), DeviceEnrollment.SoftwareKeyStorage));
    }
}
