using PabloCompanion.Models;
using PabloCompanion.Services;
using PabloCompanion.Tests.Services;
using PabloCompanion.ViewModels;

namespace PabloCompanion.Tests.ViewModels;

/// <summary>
/// The update-required screen: shown at launch when the backend's minimum is
/// above this version, held back while a recording is active, shown once it ends,
/// and reached the same way by a 426 from any request.
/// </summary>
public class UpdateGateViewModelTests
{
    private sealed class FakeVault : CredentialManager
    {
        private readonly Dictionary<string, string> _store = new();
        public override string? GetValue(string key) => _store.GetValueOrDefault(key);
        public override void SetValue(string key, string value) => _store[key] = value;
    }

    private static HealthStatus Health(string clientVersion, string minClient = "1.0.1", string server = "1.4.0")
        => APIClient.ParseHealth(
            $$$"""{"server_version": "{{{server}}}", "min_client_versions": {"windows": "{{{minClient}}}"}}""",
            clientVersion);

    [Fact]
    public void LaunchCheck_ClientBelowMinimum_ShowsUpdateRequired()
    {
        var gate = new UpdateGateViewModel(new FakeVersionProvider("1.0.0"), () => false);

        gate.ApplyHealth(Health("1.0.0"));

        var shown = Assert.IsType<UpdateRequiredReason>(gate.Shown);
        Assert.Equal(UpdateRequiredKind.ClientUpdate, shown.Kind);
        Assert.Equal("Update Required", shown.Title);
        Assert.Equal("Your app (v1.0.0) is no longer supported. Version 1.0.1 or later is required.", shown.Subtitle);
        Assert.Equal("Please download the latest version to continue.", shown.Instruction);
        Assert.True(shown.ShowsUpdateButton);
    }

    [Fact]
    public void LaunchCheck_CompatibleVersions_ShowsNothing()
    {
        var gate = new UpdateGateViewModel(new FakeVersionProvider("1.0.1"), () => false);

        gate.ApplyHealth(Health("1.0.1"));

        Assert.Null(gate.Shown);
        Assert.False(gate.IsDeferred);
    }

    [Fact]
    public void LaunchCheck_OldServer_ShowsServerVariant()
    {
        var gate = new UpdateGateViewModel(new FakeVersionProvider("1.0.0"), () => false);

        gate.ApplyHealth(Health("1.0.0", minClient: "0.0.0", server: "0.8.0"));

        var shown = Assert.IsType<UpdateRequiredReason>(gate.Shown);
        Assert.Equal(UpdateRequiredKind.ServerUpdate, shown.Kind);
        Assert.Equal("Server Update Needed", shown.Title);
        Assert.Equal("Please contact your administrator.", shown.Instruction);
        Assert.False(shown.ShowsUpdateButton);
    }

    [Fact]
    public void RecordingActive_DefersTheScreen_UntilTheRecordingEnds()
    {
        var recording = true;
        var gate = new UpdateGateViewModel(new FakeVersionProvider("1.0.0"), () => recording);

        gate.ApplyHealth(Health("1.0.0"));

        Assert.Null(gate.Shown);
        Assert.True(gate.IsDeferred);

        gate.Reevaluate(); // still recording: still waiting
        Assert.Null(gate.Shown);

        recording = false;
        gate.Reevaluate();

        Assert.NotNull(gate.Shown);
        Assert.False(gate.IsDeferred);
    }

    [Fact]
    public void Shown_IsPermanent()
    {
        var gate = new UpdateGateViewModel(new FakeVersionProvider("1.0.0"), () => false);
        gate.ApplyHealth(Health("1.0.0"));
        var first = gate.Shown;

        gate.ApplyHealth(Health("1.0.0", minClient: "0.0.0"));
        gate.Reevaluate();

        Assert.Same(first, gate.Shown);
    }

    [Fact]
    public void Http426_TriggersTheSameGate()
    {
        var vault = new FakeVault();
        var api = new APIClient(vault, new DeviceKeyService(vault), new FakeVersionProvider("1.0.0"));
        var gate = new UpdateGateViewModel(new FakeVersionProvider("1.0.0"), () => false);
        gate.Attach(api);

        api.NotifyIfUpdateRequired(APIClient.MapError(426, ""));

        var shown = Assert.IsType<UpdateRequiredReason>(gate.Shown);
        Assert.Equal(UpdateRequiredKind.ClientUpdate, shown.Kind);
        Assert.Equal("Your app (v1.0.0) is no longer supported.", shown.Subtitle);
    }

    [Fact]
    public void Http426_MidRecording_WaitsForTheRecordingToEnd()
    {
        var recording = true;
        var vault = new FakeVault();
        var api = new APIClient(vault, new DeviceKeyService(vault), new FakeVersionProvider("1.0.0"));
        var gate = new UpdateGateViewModel(new FakeVersionProvider("1.0.0"), () => recording);
        gate.Attach(api);
        gate.ApplyHealth(Health("1.0.0", minClient: "0.9.0")); // compatible at launch

        api.NotifyIfUpdateRequired(APIClient.MapError(426, ""));
        Assert.Null(gate.Shown);
        Assert.True(gate.IsDeferred);

        recording = false;
        gate.Reevaluate();

        var shown = Assert.IsType<UpdateRequiredReason>(gate.Shown);
        // The minimum from the launch check is carried into the 426 copy.
        Assert.Equal("Your app (v1.0.0) is no longer supported. Version 0.9.0 or later is required.", shown.Subtitle);
    }
}
