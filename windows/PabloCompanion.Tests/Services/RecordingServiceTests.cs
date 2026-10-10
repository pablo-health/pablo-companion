using AudioCapture.Interfaces;
using AudioCapture.Models;
using AudioCapture.Storage;
using PabloCompanion.Services;
using PabloCompanion.Tests.Helpers;

namespace PabloCompanion.Tests.Services;

/// <summary>
/// The capture lifecycle over injected sources: fail closed without a key,
/// start returns only once capturing, a lost mic stops the capture and says so,
/// and a restart appends to the session's one sidecar pair.
/// </summary>
[Collection("RecordingCapture")]
public sealed class RecordingServiceTests
{
    private static readonly TimeSpan OneSecond = TimeSpan.FromSeconds(1);

    [Fact]
    public async Task WithoutAKey_StartThrowsAndWritesNothing()
    {
        using var rig = new CaptureRig(key: null);

        await Assert.ThrowsAsync<RecordingEncryptionUnavailableException>(
            () => rig.Service.StartAsync("session-1", exportRawPcm: true));

        Assert.False(Directory.Exists(rig.Root), "no recording directory may be created without a key");
        Assert.Empty(rig.Sessions);
        Assert.False(rig.Service.IsRecording);
    }

    [Fact]
    public async Task StartReturnsOnceCapturing()
    {
        using var rig = new CaptureRig(KeyCredentialManager.NewKey());

        await rig.Service.StartAsync("session-1", exportRawPcm: true);

        Assert.Equal(CaptureStateKind.Capturing, Assert.Single(rig.Sessions).State.Kind);
        Assert.True(rig.Service.IsRecording);
        await rig.Service.StopAsync();
    }

    [Fact]
    public async Task AStartThatFails_LeavesNothingRunning_AndALaterStartWorks()
    {
        using var rig = new CaptureRig(KeyCredentialManager.NewKey());
        await rig.Service.StartAsync("session-1", exportRawPcm: true);

        // A second start while one is live is refused and leaves the first alone.
        await Assert.ThrowsAsync<InvalidOperationException>(() => rig.Service.StartAsync("session-2"));
        Assert.True(rig.Service.IsRecording);

        await rig.Service.StopAsync();
        await rig.Service.StartAsync("session-2", exportRawPcm: true);
        Assert.True(rig.Service.IsRecording);
        await rig.Service.StopAsync();
    }

    [Fact]
    public async Task MicRecordingStoppedWithAnError_StopsTheCaptureAsMicDisconnected()
    {
        using var rig = new CaptureRig(KeyCredentialManager.NewKey());
        var stopped = new TaskCompletionSource<CaptureStoppedEventArgs>(TaskCreationOptions.RunContinuationsAsynchronously);
        rig.Service.CaptureStopped += (_, e) => stopped.TrySetResult(e);
        await rig.Service.StartAsync("session-1", exportRawPcm: true);
        await Task.Delay(300);

        rig.Mics[0].Fail(new InvalidOperationException("device removed"));

        var e = await stopped.Task.WaitAsync(OneSecond);
        Assert.Equal(CaptureStopReason.MicDisconnected, e.Reason);
        Assert.Equal("session-1", e.SessionId);
        Assert.NotNull(e.Recording);
        Assert.False(rig.Service.IsRecording);

        // What was recorded before the mic went is saved and decrypts.
        var pcm = SidecarStreamWriter.ReadEncrypted(e.Recording!.MicPcmFilePath!, Decryptor(rig));
        Assert.NotEmpty(pcm);
    }

    [Fact]
    public async Task DeviceChangeMicDisconnected_StopsTheCaptureAsMicDisconnected()
    {
        using var rig = new CaptureRig(KeyCredentialManager.NewKey());
        var stopped = new TaskCompletionSource<CaptureStoppedEventArgs>(TaskCreationOptions.RunContinuationsAsynchronously);
        rig.Service.CaptureStopped += (_, e) => stopped.TrySetResult(e);
        await rig.Service.StartAsync("session-1", exportRawPcm: true);

        rig.Sessions[0].Delegate!.OnDeviceChanged(
            new CaptureDeviceChange(CaptureDeviceChangeKind.MicDisconnected, "{mic}", "device-state-changed"));

        var e = await stopped.Task.WaitAsync(OneSecond);
        Assert.Equal(CaptureStopReason.MicDisconnected, e.Reason);
        Assert.False(rig.Service.IsRecording);
    }

    [Fact]
    public async Task SystemAudioLoss_IsReportedButTheCaptureCarriesOn()
    {
        using var rig = new CaptureRig(KeyCredentialManager.NewKey());
        var interrupted = 0;
        var restored = 0;
        var stoppedOnItsOwn = false;
        rig.Service.SystemAudioInterrupted += (_, _) => Interlocked.Increment(ref interrupted);
        rig.Service.SystemAudioRestored += (_, _) => Interlocked.Increment(ref restored);
        rig.Service.CaptureStopped += (_, _) => stoppedOnItsOwn = true;
        await rig.Service.StartAsync("session-1", exportRawPcm: true);
        var listener = rig.Sessions[0].Delegate!;

        listener.OnError(CaptureException.DeviceNotAvailable("System audio stopped: endpoint invalidated"));
        listener.OnDeviceChanged(new CaptureDeviceChange(CaptureDeviceChangeKind.SystemOutputUnavailable, null, "capture-error"));
        listener.OnDeviceChanged(new CaptureDeviceChange(CaptureDeviceChangeKind.SystemOutputSwitched, "{headset}", "default-device-changed"));
        await Task.Delay(200);

        Assert.Equal(2, interrupted);
        Assert.Equal(1, restored);
        Assert.False(stoppedOnItsOwn);
        Assert.True(rig.Service.IsRecording);
        await rig.Service.StopAsync();
    }

    [Fact]
    public async Task ACallbackFromAnEarlierCapture_IsIgnored()
    {
        using var rig = new CaptureRig(KeyCredentialManager.NewKey());
        var stoppedOnItsOwn = false;
        rig.Service.CaptureStopped += (_, _) => stoppedOnItsOwn = true;
        await rig.Service.StartAsync("session-1", exportRawPcm: true);
        var firstListener = rig.Sessions[0].Delegate!;
        await rig.Service.StopAsync();
        await rig.Service.StartAsync("session-1", exportRawPcm: true);

        firstListener.OnDeviceChanged(new CaptureDeviceChange(CaptureDeviceChangeKind.MicDisconnected, "{mic}", "late"));
        await Task.Delay(200);

        Assert.False(stoppedOnItsOwn);
        Assert.True(rig.Service.IsRecording);
        await rig.Service.StopAsync();
    }

    [Fact]
    public async Task ARestartAppendsToOneMicSidecarThatDecryptsEndToEnd()
    {
        using var rig = new CaptureRig(KeyCredentialManager.NewKey());

        await rig.Service.StartAsync("session-1", exportRawPcm: true);
        await Task.Delay(TimeSpan.FromSeconds(0.8));
        var first = await rig.Service.StopAsync();
        var afterFirst = File.ReadAllBytes(first.MicPcmFilePath!);
        var firstPcm = SidecarStreamWriter.ReadEncrypted(first.MicPcmFilePath!, Decryptor(rig));

        // Restart Recording: a new capture for the same session.
        await rig.Service.StartAsync("session-1", exportRawPcm: true);
        await Task.Delay(TimeSpan.FromSeconds(0.8));
        var second = await rig.Service.StopAsync();

        // One sidecar per channel, at the same paths, in the session's directory.
        Assert.Equal(first.MicPcmFilePath, second.MicPcmFilePath);
        Assert.Equal(first.SystemPcmFilePath, second.SystemPcmFilePath);
        var sessionDir = rig.Service.SessionDirectory("session-1");
        Assert.Single(Directory.GetFiles(sessionDir, "*_mic.enc.pcm"));
        Assert.Single(Directory.GetFiles(sessionDir, "*_system.enc.pcm"));

        // The first run is an untouched prefix, and the whole file decrypts as one stream.
        var combined = File.ReadAllBytes(second.MicPcmFilePath!);
        Assert.True(combined.Length > afterFirst.Length);
        Assert.Equal(afterFirst, combined[..afterFirst.Length]);
        var combinedPcm = SidecarStreamWriter.ReadEncrypted(second.MicPcmFilePath!, Decryptor(rig));
        Assert.InRange(combinedPcm.Length, (long)(firstPcm.Length * 1.5), (long)(firstPcm.Length * 2.5));
        Assert.Equal(firstPcm, combinedPcm[..firstPcm.Length]);

        // The upload path reads it the same way.
        using var encryptor = new AesGcmEncryptor(rig.Key!, "device-key");
        using var decrypted = await PcmDecryptor.PrepareForUploadAsync(second.MicPcmFilePath!, encryptor);
        Assert.Equal(combinedPcm, File.ReadAllBytes(decrypted.Path));

        // The session's duration spans both runs.
        Assert.True(second.Duration > first.Duration * 1.5, $"{second.Duration} vs {first.Duration}");
        Assert.True(second.IsEncrypted);
    }

    [Fact]
    public async Task WithNoMicPicked_TheCaptureAsksForTheDefaultMic_AndFollowsTheDefaultOutput()
    {
        using var rig = new CaptureRig(KeyCredentialManager.NewKey());

        await rig.Service.StartAsync("session-1", micDeviceId: null, exportRawPcm: true);

        // A null mic id is what the capture resolves to the default communications
        // mic at start; an id would pin one device.
        var config = rig.Service.LastConfiguration!;
        Assert.Null(config.MicDeviceId);
        Assert.True(config.FollowDefaultOutputDevice);
        await rig.Service.StopAsync();
    }

    [Fact]
    public async Task WithNoMicPicked_AfterTheDefaultMicChangesAndTheOldOneGoes_TheRestartRecordsTheNewDefault()
    {
        using var rig = new CaptureRig(KeyCredentialManager.NewKey());
        var stopped = new TaskCompletionSource<CaptureStoppedEventArgs>(TaskCreationOptions.RunContinuationsAsynchronously);
        rig.Service.CaptureStopped += (_, e) => stopped.TrySetResult(e);
        await rig.Service.StartAsync("session-1", exportRawPcm: true);
        await Task.Delay(300);
        var oldMic = rig.Mics[0];

        // A headset connects and becomes the default; then the old mic goes away.
        FailableWaveIn? headset = null;
        rig.MicSource = () => headset = FailableWaveIn.Mic();
        oldMic.Fail(new InvalidOperationException("device removed"));
        var e = await stopped.Task.WaitAsync(OneSecond);
        Assert.Equal(CaptureStopReason.MicDisconnected, e.Reason);
        var beforeRestart = SidecarStreamWriter.ReadEncrypted(e.Recording!.MicPcmFilePath!, Decryptor(rig));

        // Restart Recording, still with no mic picked: the capture opens the new default.
        await rig.Service.StartAsync("session-1", micDeviceId: null, exportRawPcm: true);
        await Task.Delay(500);
        var recording = await rig.Service.StopAsync();

        Assert.NotNull(headset);
        Assert.Same(headset, rig.Mics[^1]);
        Assert.True(rig.Sessions[^1].Diagnostics.MicChunks > 0, "the new default mic delivered audio");
        var combined = SidecarStreamWriter.ReadEncrypted(recording.MicPcmFilePath!, Decryptor(rig));
        Assert.True(combined.Length > beforeRestart.Length, "the new mic's audio appended to the session's sidecar");
    }

    [Fact]
    public async Task ASystemSourceError_IsReportedAsInterrupted_AndTheCaptureReopensItAndReportsItRestored()
    {
        using var rig = new CaptureRig(KeyCredentialManager.NewKey());
        var interrupted = 0;
        var restored = 0;
        rig.Service.SystemAudioInterrupted += (_, _) => Interlocked.Increment(ref interrupted);
        rig.Service.SystemAudioRestored += (_, _) => Interlocked.Increment(ref restored);
        await rig.Service.StartAsync("session-1", exportRawPcm: true);
        await Task.Delay(200);

        // The output endpoint is invalidated (a route or format change). Following
        // the default output, the capture re-opens system audio on its own.
        rig.Systems[0].Fail(new InvalidOperationException("endpoint invalidated"));

        await Eventually.TrueAsync(() => Volatile.Read(ref interrupted) > 0, OneSecond, "the system-audio error to be reported");
        await Eventually.TrueAsync(() => Volatile.Read(ref restored) > 0, TimeSpan.FromSeconds(3), "system audio to be re-opened");
        Assert.True(rig.Systems.Length >= 2, "a new system source was opened");
        var diagnostics = rig.Sessions[0].Diagnostics;
        Assert.Equal(1, diagnostics.SystemSourceErrors);
        Assert.True(diagnostics.SystemSourceSwitches >= 1);
        Assert.True(rig.Service.IsRecording);
        await rig.Service.StopAsync();
    }

    [Theory]
    [InlineData(48000, 48000)]
    [InlineData(16000, 16000)]
    public async Task TheRecordingCarriesTheRateTheMicSidecarIsWrittenAt(int micRate, int expected)
    {
        using var rig = new CaptureRig(KeyCredentialManager.NewKey()) { MicSource = () => FailableWaveIn.Mic(micRate) };

        await rig.Service.StartAsync("session-1", exportRawPcm: true);
        await Task.Delay(TimeSpan.FromSeconds(1.2));
        var recording = await rig.Service.StopAsync();

        Assert.Equal(expected, recording.SampleRate);
        Assert.Equal(micRate, rig.Sessions[0].Diagnostics.MicSampleRate);

        // The header rate describes the bytes: mono 16-bit at that rate is rate * 2
        // bytes a second. A 16 kHz mic headed as 48 kHz would be a third of that.
        var pcm = SidecarStreamWriter.ReadEncrypted(recording.MicPcmFilePath!, Decryptor(rig));
        var bytesPerSecond = pcm.Length / recording.Duration;
        Assert.InRange(bytesPerSecond, expected * 2 * 0.75, expected * 2 * 1.25);
    }

    [Theory]
    [InlineData(48000, 48000, 1, 48000)]
    [InlineData(16000, 48000, 1, 16000)]
    [InlineData(0, 48000, 0, 48000)]
    [InlineData(0, 0, 0, 48000)]
    public void SidecarSampleRate_IsTheMicsDeliveredRate_ElseTheSidecarRate(
        int micRate, int sidecarRate, int micChannels, int expected)
    {
        var diagnostics = new CaptureDiagnostics
        {
            MicSampleRate = micRate,
            MicChannels = micChannels,
            MicBitsPerSample = micChannels > 0 ? 16 : 0,
            SidecarSampleRate = sidecarRate,
            MicMeasuredSampleRate = micRate * 0.99,
        };

        Assert.Equal(expected, RecordingService.SidecarSampleRate(diagnostics));
    }

    /// <summary>
    /// The 48 kHz header on a real mic rests on this: NAudio's shared-mode
    /// <c>WasapiCapture</c> asks Windows to convert to the format the capture sets
    /// (48 kHz mono 16-bit), so a 16 kHz hands-free mic arrives already resampled and
    /// the mic sidecar is at the configured rate. Without the flag the format would be
    /// refused or delivered as the device's own, and the rate would have to come from
    /// the device instead.
    /// </summary>
    [Fact]
    public void NAudioSharedModeMicCapture_AsksWindowsToConvertToTheRequestedFormat()
    {
        var capture = (NAudio.CoreAudioApi.WasapiCapture)System.Runtime.CompilerServices.RuntimeHelpers
            .GetUninitializedObject(typeof(NAudio.CoreAudioApi.WasapiCapture));
        var method = typeof(NAudio.CoreAudioApi.WasapiCapture).GetMethod(
            "GetAudioClientStreamFlags",
            System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);
        Assert.NotNull(method);

        var flags = (NAudio.CoreAudioApi.AudioClientStreamFlags)method!.Invoke(capture, null)!;

        Assert.Equal(NAudio.CoreAudioApi.AudioClientShareMode.Shared, capture.ShareMode);
        Assert.True(flags.HasFlag(NAudio.CoreAudioApi.AudioClientStreamFlags.AutoConvertPcm), $"flags were {flags}");
    }

    private static Func<byte[], byte[]> Decryptor(CaptureRig rig)
    {
        var encryptor = new AesGcmEncryptor(rig.Key!, "device-key");
        return encryptor.Decrypt;
    }
}
