using PabloCompanion.Models;
using PabloCompanion.Services;

namespace PabloCompanion.Tests.Services;

/// <summary>A fixed version, standing in for the package version.</summary>
internal sealed class FakeVersionProvider(string version) : IAppVersionProvider
{
    public string Version { get; } = version;
}

/// <summary>
/// The version the backend and the user see comes from the package (here, the
/// provider seam), never a constant.
/// </summary>
public class AppVersionTests
{
    private sealed class FakeVault : CredentialManager
    {
        private readonly Dictionary<string, string> _store = new();
        public override string? GetValue(string key) => _store.GetValueOrDefault(key);
        public override void SetValue(string key, string value) => _store[key] = value;
    }

    [Fact]
    public void ClientVersionHeader_IsTheProvidedVersion()
    {
        var vault = new FakeVault();
        var api = new APIClient(vault, new DeviceKeyService(vault), new FakeVersionProvider("1.2.3"));

        using var request = api.CreateRequest(HttpMethod.Get, "/api/health", authenticated: false);

        Assert.Equal("1.2.3", api.ClientVersion);
        Assert.Equal(["1.2.3"], request.Headers.GetValues("X-Client-Version"));
    }

    [Fact]
    public void VersionLabel_IsTheProvidedVersion()
    {
        Assert.Equal("Pablo Companion (Windows) v1.2.3", AppVersion.Label(new FakeVersionProvider("1.2.3")));
    }

    [Fact]
    public void PackageProvider_WithoutPackageIdentity_FallsBackToTheAssemblyVersion()
    {
        // The unpackaged test host has no identity; reading must not throw.
        Assert.False(PackageAppVersionProvider.HasPackageIdentity());
        Assert.Matches(@"^\d+\.\d+\.\d+$", new PackageAppVersionProvider().Version);
    }

    [Fact]
    public void ParseHealth_ClientBelowMinimum_RequiresClientUpdate()
    {
        var status = APIClient.ParseHealth(
            """{"server_version": "1.4.0", "min_client_versions": {"windows": "1.0.1", "macos": "2.0.0"}}""",
            clientVersion: "1.0.0");

        Assert.True(status.ClientUpdateRequired);
        Assert.False(status.ServerUpdateRequired);
        Assert.Equal("1.0.1", status.MinClientVersion);
    }

    [Theory]
    [InlineData("1.0.1")]
    [InlineData("1.2.0")]
    public void ParseHealth_ClientAtOrAboveMinimum_RequiresNothing(string clientVersion)
    {
        var status = APIClient.ParseHealth(
            """{"server_version": "1.4.0", "min_client_versions": {"windows": "1.0.1"}}""", clientVersion);

        Assert.False(status.ClientUpdateRequired);
    }

    [Fact]
    public void ParseHealth_OldServer_RequiresServerUpdate()
    {
        var status = APIClient.ParseHealth("""{"server_version": "0.8.0"}""", clientVersion: "1.0.0");

        Assert.True(status.ServerUpdateRequired);
        Assert.False(status.ClientUpdateRequired);
    }

    [Fact]
    public void MapError_426_CarriesTheTypedUpdateRequiredCode()
    {
        var error = APIClient.MapError(426, """{"error": {"code": "SOMETHING_ELSE", "message": "Too old"}}""");

        Assert.Equal(PabloException.UpdateRequiredCode, error.ErrorCode);
        Assert.True(error.IsUpdateRequired);
        Assert.False(APIClient.MapError(400, "").IsUpdateRequired);
    }

    [Fact]
    public void NotifyIfUpdateRequired_RaisesOnlyFor426()
    {
        var vault = new FakeVault();
        var api = new APIClient(vault, new DeviceKeyService(vault), new FakeVersionProvider("1.0.0"));
        var raised = 0;
        api.UpdateRequiredDetected += _ => raised++;

        api.NotifyIfUpdateRequired(APIClient.MapError(500, "boom"));
        Assert.Equal(0, raised);

        api.NotifyIfUpdateRequired(APIClient.MapError(426, ""));
        Assert.Equal(1, raised);
    }
}
