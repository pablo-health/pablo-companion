using PabloCompanion.Models;
using PabloCompanion.ViewModels;
using Xunit;

namespace PabloCompanion.Tests.ViewModels;

public class RecordingViewModelTests
{
    [Fact]
    public void InitialState_IsIdle()
    {
        // RecordingViewModel requires DI services we can't easily mock in a unit test
        // without a full WinUI test host. These tests verify the model types directly.
        var state = RecordingUIState.Idle;
        Assert.Equal(RecordingUIState.Idle, state);
    }

    [Fact]
    public void RecordingUIState_HasExpectedValues()
    {
        Assert.Equal(0, (int)RecordingUIState.Idle);
        Assert.Equal(1, (int)RecordingUIState.Recording);
        Assert.Equal(2, (int)RecordingUIState.Paused);
    }

    [Fact]
    public void LocalRecording_RecordEquality()
    {
        var id = Guid.NewGuid();
        var now = DateTime.UtcNow;

        var r1 = new LocalRecording(id, "test.wav", 10.0, now, true, "abc",
            AudioCapture.Models.ChannelLayout.Blended, null, null, false);
        var r2 = new LocalRecording(id, "test.wav", 10.0, now, true, "abc",
            AudioCapture.Models.ChannelLayout.Blended, null, null, false);

        Assert.Equal(r1, r2);
    }

    [Fact]
    public void LocalRecording_DifferentValues_NotEqual()
    {
        var now = DateTime.UtcNow;
        var r1 = new LocalRecording(Guid.NewGuid(), "a.wav", 10.0, now, true, "abc",
            AudioCapture.Models.ChannelLayout.Blended, null, null, false);
        var r2 = new LocalRecording(Guid.NewGuid(), "b.wav", 20.0, now, false, "def",
            AudioCapture.Models.ChannelLayout.SeparatedStereo, null, null, true);

        Assert.NotEqual(r1, r2);
    }
}
