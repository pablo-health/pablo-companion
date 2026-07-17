using System.Buffers.Binary;
using NAudio.Wave;
using RecordHarness;

namespace PabloCompanion.Tests.Harness;

/// <summary>
/// Drives the harness's capture leg — the exact RecordingService config with
/// fixtures injected — and checks the sidecars it hands the upload path.
///
/// This is the leg that decides whether a CI run gates on real audio or on
/// silence, and it's the half of the scenario with no network in it, so it can be
/// proven here rather than discovered on a runner.
/// </summary>
public class FixtureRecorderTests : IDisposable
{
    private readonly string _tempDir;

    public FixtureRecorderTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), $"harness_test_{Guid.NewGuid():N}");
        Directory.CreateDirectory(_tempDir);
    }

    public void Dispose()
    {
        GC.SuppressFinalize(this);
        if (Directory.Exists(_tempDir))
            Directory.Delete(_tempDir, recursive: true);
    }

    /// <summary>
    /// A tone fixture standing in for CI's System.Speech output: 48 kHz, 16-bit,
    /// mono — the format the workflow synthesizes.
    /// </summary>
    private string WriteToneFixture(string name, double seconds = 1.0, double amplitude = 0.5)
    {
        var path = Path.Combine(_tempDir, name);
        using var writer = new WaveFileWriter(path, new WaveFormat(48000, 16, 1));
        var frames = (int)(48000 * seconds);
        for (int i = 0; i < frames; i++)
            writer.WriteSample((float)(Math.Sin(2 * Math.PI * 440 * i / 48000) * amplitude));
        return path;
    }

    private string WriteSilentFixture(string name, double seconds = 1.0)
    {
        var path = Path.Combine(_tempDir, name);
        using var writer = new WaveFileWriter(path, new WaveFormat(48000, 16, 1));
        for (int i = 0; i < (int)(48000 * seconds); i++)
            writer.WriteSample(0f);
        return path;
    }

    [Fact]
    public async Task Record_ProducesBothSidecarsWithLiveAudio()
    {
        var mic = WriteToneFixture("mic.wav");
        var system = WriteToneFixture("system.wav");

        var outcome = await FixtureRecorder.RecordAsync(mic, system, seconds: 1.0, outputDirectory: _tempDir);

        Assert.True(outcome.Ok, $"capture should have run the mix path: {outcome.Detail}");
        Assert.Equal(0, outcome.MixErrors);
        Assert.True(File.Exists(outcome.MicPath), "mic sidecar should exist");
        Assert.NotNull(outcome.SystemPath);
        Assert.True(File.Exists(outcome.SystemPath!), "system sidecar should exist");

        // The gate's liveness threshold. A silent channel sits at ~0; speech at
        // half scale is in the thousands, so this has a wide margin.
        Assert.True(outcome.MicRms > 1, $"mic RMS was {outcome.MicRms:F2}");
        Assert.True(outcome.SystemRms > 1, $"system RMS was {outcome.SystemRms:F2}");
    }

    [Fact]
    public async Task Record_LoopsAShortFixtureToFillTheWindow()
    {
        // Fixtures are ~7s of synthesized speech but captures run 20s+. Without
        // looping the tail is silence, which drags RMS toward the liveness floor.
        var mic = WriteToneFixture("mic.wav", seconds: 0.2);
        var system = WriteToneFixture("system.wav", seconds: 0.2);

        var outcome = await FixtureRecorder.RecordAsync(mic, system, seconds: 1.5, outputDirectory: _tempDir);

        // 1.5s of mono 16-bit at 48 kHz ≈ 144 000 bytes; a single 0.2s pass is
        // ~19 200. Anything near the latter means looping didn't happen.
        var micBytes = new FileInfo(outcome.MicPath).Length;
        Assert.True(micBytes > 60_000, $"mic sidecar was only {micBytes} bytes — fixture likely did not loop");
        Assert.True(outcome.MicRms > 1, $"mic RMS was {outcome.MicRms:F2}");
    }

    [Fact]
    public async Task Record_SilentFixtureFailsTheLivenessCheck()
    {
        // Proves the liveness check can actually fail — otherwise a passing gate
        // says nothing about whether audio was captured.
        var mic = WriteSilentFixture("silent.wav");
        var system = WriteToneFixture("system.wav");

        var outcome = await FixtureRecorder.RecordAsync(mic, system, seconds: 1.0, outputDirectory: _tempDir);

        Assert.True(outcome.MicRms <= 1, $"silent mic should read as dead, got {outcome.MicRms:F2}");
        Assert.True(outcome.SystemRms > 1, "system channel should still be live");
    }

    [Fact]
    public async Task MicSidecar_IsMonoAndSystemSidecarIsStereo()
    {
        // The upload path stamps WAV headers on these assuming mic=mono and
        // system=stereo. If the sidecar shapes ever diverge from that, the headers
        // silently misdescribe the audio — the exact bug this epic exists to fix.
        var mic = WriteToneFixture("mic.wav");
        var system = WriteToneFixture("system.wav");

        var outcome = await FixtureRecorder.RecordAsync(mic, system, seconds: 1.0, outputDirectory: _tempDir);

        var micBytes = new FileInfo(outcome.MicPath).Length;
        var systemBytes = new FileInfo(outcome.SystemPath!).Length;

        // Same wall-clock window, same rate: stereo carries two samples per frame,
        // so it should be roughly twice the mono channel.
        var ratio = (double)systemBytes / micBytes;
        Assert.InRange(ratio, 1.6, 2.4);
    }

    [Fact]
    public void PcmRms_IsZeroForSilenceAndPositiveForSignal()
    {
        var silence = Path.Combine(_tempDir, "silence.pcm");
        File.WriteAllBytes(silence, new byte[4096]);
        Assert.Equal(0, FixtureRecorder.PcmRms(silence));

        var signal = Path.Combine(_tempDir, "signal.pcm");
        var pcm = new byte[4096];
        for (int i = 0; i + 1 < pcm.Length; i += 2)
            BinaryPrimitives.WriteInt16LittleEndian(pcm.AsSpan(i, 2), 8000);
        File.WriteAllBytes(signal, pcm);
        Assert.Equal(8000, FixtureRecorder.PcmRms(signal), 1.0);
    }

    [Fact]
    public void PcmRms_EmptyFileIsZeroRatherThanNaN()
    {
        // A zero-length sidecar would divide by zero; the gate must read it as a
        // dead channel, not crash the run.
        var empty = Path.Combine(_tempDir, "empty.pcm");
        File.WriteAllBytes(empty, []);

        Assert.Equal(0, FixtureRecorder.PcmRms(empty));
    }
}
