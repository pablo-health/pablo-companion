using System.Security.Cryptography;
using PabloCompanion.Services;

namespace PabloCompanion.Tests.Services;

/// <summary>
/// The DPoP / X-Install-ID pair must go out together or not at all. The server's
/// middleware 401s an <c>X-Install-ID</c> that arrives without a valid proof, so these
/// tests pin the enrollment-state matrix: enrolled → both headers; no install id → none;
/// install id but no key → none; signing throws → none. Never the id header alone.
/// </summary>
public class DeviceBindingTests
{
    private const string Url = "https://api.pablo.health/api/sessions?page=1";

    /// <summary>
    /// In-memory credential vault. Serves a fixed install id and an optional stored
    /// P-256 private key (PKCS#8, base64) under the same key names the production code
    /// reads, so DeviceKeyService and APIClient see a coherent enrollment state.
    /// </summary>
    private sealed class FakeVault : CredentialManager
    {
        private readonly Dictionary<string, string> _store = new();

        public FakeVault(string? installId, bool withDeviceKey)
        {
            if (installId is not null) _store["installId"] = installId;
            if (withDeviceKey)
            {
                using var k = ECDsa.Create(ECCurve.NamedCurves.nistP256);
                _store["deviceKeyPkcs8"] = Convert.ToBase64String(k.ExportPkcs8PrivateKey());
            }
        }

        public void Set(string key, string value) => _store[key] = value;

        public override string? GetValue(string key) => _store.GetValueOrDefault(key);
        public override void SetValue(string key, string value) => _store[key] = value;
    }

    [Fact]
    public void BuildDeviceBinding_Enrolled_ReturnsBothHeaders()
    {
        var vault = new FakeVault("install-123", withDeviceKey: true);
        var api = new APIClient(vault, new DeviceKeyService(vault));

        var (proof, installId) = api.BuildDeviceBinding("GET", Url);

        Assert.Equal("install-123", installId);
        Assert.False(string.IsNullOrEmpty(proof));
        Assert.Equal(3, proof!.Split('.').Length); // compact JWS
    }

    [Fact]
    public void BuildDeviceBinding_NoInstallId_ReturnsNeither()
    {
        // A key without an install id is still "not enrolled" — send no headers.
        var vault = new FakeVault(installId: null, withDeviceKey: true);
        var api = new APIClient(vault, new DeviceKeyService(vault));

        var (proof, installId) = api.BuildDeviceBinding("GET", Url);

        Assert.Null(proof);
        Assert.Null(installId);
    }

    [Fact]
    public void BuildDeviceBinding_InstallIdButNoKey_ReturnsNeither()
    {
        // Install id present but the device never minted a key: must NOT send the id
        // alone (that is the guaranteed-401 combination).
        var vault = new FakeVault("install-123", withDeviceKey: false);
        var api = new APIClient(vault, new DeviceKeyService(vault));

        var (proof, installId) = api.BuildDeviceBinding("GET", Url);

        Assert.Null(proof);
        Assert.Null(installId);
    }

    [Fact]
    public void BuildDeviceBinding_CorruptKey_ReturnsNeither()
    {
        // An unreadable stored key blob must degrade to a legacy bearer request, not a
        // half-attached id-only request.
        var vault = new FakeVault("install-123", withDeviceKey: false);
        vault.Set("deviceKeyPkcs8", "not-a-valid-base64-pkcs8-blob!!");
        var api = new APIClient(vault, new DeviceKeyService(vault));

        var (proof, installId) = api.BuildDeviceBinding("GET", Url);

        Assert.Null(proof);
        Assert.Null(installId);
    }

    [Fact]
    public void TryCreateProof_NoKey_ReturnsNull_DoesNotMint()
    {
        // TryCreateProof must never mint a key — signing a proof for a never-enrolled
        // device would attach proof material the backend has no public key to verify.
        var vault = new FakeVault("install-123", withDeviceKey: false);
        var deviceKey = new DeviceKeyService(vault);

        Assert.Null(deviceKey.TryCreateProof("GET", Url));
        Assert.Null(vault.GetValue("deviceKeyPkcs8"));
    }

    [Fact]
    public void TryCreateProof_Enrolled_ReusesSameKeyAcrossCalls()
    {
        var vault = new FakeVault("install-123", withDeviceKey: true);
        var deviceKey = new DeviceKeyService(vault);
        var keyBefore = vault.GetValue("deviceKeyPkcs8");

        var proof = deviceKey.TryCreateProof("GET", Url);

        Assert.False(string.IsNullOrEmpty(proof));
        // Proof signing must not rotate or re-persist the enrolled key.
        Assert.Equal(keyBefore, vault.GetValue("deviceKeyPkcs8"));
    }
}
