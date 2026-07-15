using System.Buffers.Binary;
using AudioCapture.Capture;
using AudioCapture.Models;

namespace RecordHarness;

/// <summary>
/// Drives the real capture graph from file fixtures instead of live hardware,
/// using the exact configuration the shipping RecordingService uses (48 kHz,
/// 16-bit, separated stereo, raw-PCM sidecars).
///
/// This is the part of the scenario with no network in it, so it's the part that
/// can be proven locally — hence its own type rather than a private method.
/// </summary>
internal static class FixtureRecorder
{
    /// <param name="Ok">Whether the mix path actually ran and wrote audio.</param>
    /// <param name="Detail">Human-readable diagnostics for the gate summary.</param>
    /// <param name="MicPath">Therapist (mono) PCM sidecar — what gets uploaded.</param>
    /// <param name="SystemPath">Client (stereo) PCM sidecar, when system capture ran.</param>
    /// <param name="MicRms">RMS of the mic sidecar; near zero means silence.</param>
    /// <param name="SystemRms">RMS of the system sidecar.</param>
    /// <param name="MixErrors">Mix/write cycles that threw — non-zero means audio was lost.</param>
    internal sealed record Outcome(
        bool Ok, string Detail, string MicPath, string? SystemPath,
        double MicRms, double SystemRms, long MixErrors);

    /// <summary>
    /// Records <paramref name="seconds"/> of audio with the mic and system
    /// fixtures injected through <see cref="FileWaveIn"/>. Fixtures loop, so a
    /// short clip fills the whole capture window rather than trailing into
    /// silence — the liveness check would read that silence as a dead channel.
    /// </summary>
    internal static async Task<Outcome> RecordAsync(
        string micFixture,
        string systemFixture,
        double seconds,
        string? outputDirectory = null,
        CancellationToken cancellationToken = default)
    {
        var tempDir = outputDirectory ?? Path.Combine(Path.GetTempPath(), $"record-{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempDir);

        var config = new CaptureConfiguration
        {
            SampleRate = 48000,
            BitDepth = 16,
            Channels = 2,
            OutputDirectory = tempDir,
            EnableMicCapture = true,
            EnableSystemCapture = true,
            MixingStrategy = MixingStrategy.Separated,
            ExportRawPcm = true,
        };

        using var session = new WasapiCaptureSession(
            () => FileWaveIn.Mono16(micFixture, loop: true),
            () => FileWaveIn.StereoFloat(systemFixture, loop: true));

        session.Configure(config);

        // StartCaptureAsync only completes once stopped, so don't await it here.
        var capture = session.StartCaptureAsync();
        await Task.Delay(TimeSpan.FromSeconds(seconds), cancellationToken);
        var result = await session.StopCaptureAsync();
        await capture;

        var diagnostics = session.Diagnostics;
        var micPath = result.RawPcmFilePaths.ElementAtOrDefault(0)
            ?? throw new HarnessException("no mic PCM sidecar produced");
        var systemPath = result.RawPcmFilePaths.ElementAtOrDefault(1);

        return new Outcome(
            Ok: diagnostics.MixCycles >= 1 && diagnostics.BytesWritten > 0,
            Detail: $"mixCycles {diagnostics.MixCycles}, bytes {diagnostics.BytesWritten}",
            MicPath: micPath,
            SystemPath: systemPath,
            MicRms: PcmRms(micPath),
            SystemRms: systemPath is null ? 0 : PcmRms(systemPath),
            MixErrors: diagnostics.MixErrors);
    }

    /// <summary>
    /// RMS of a raw signed-16-bit-LE PCM sidecar — a cheap "is this speech, not
    /// silence" liveness check on each captured channel.
    /// </summary>
    internal static double PcmRms(string path)
    {
        var data = File.ReadAllBytes(path);
        if (data.Length < 2) return 0;

        var sampleCount = data.Length / 2;
        double sumSquares = 0;
        for (int i = 0; i < sampleCount; i++)
        {
            double value = BinaryPrimitives.ReadInt16LittleEndian(data.AsSpan(i * 2, 2));
            sumSquares += value * value;
        }
        return Math.Sqrt(sumSquares / sampleCount);
    }
}
