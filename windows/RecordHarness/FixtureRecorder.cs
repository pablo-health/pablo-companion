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
///
/// Shared by the <c>record</c> and <c>visit</c> scenarios so both gate the same
/// capture. The Windows mirror of the macOS harness's <c>FixtureCapture</c>.
/// </summary>
internal static class FixtureRecorder
{
    /// <summary>
    /// The heartbeat cadence the shipping app uses while recording. During capture
    /// the client makes no other backend calls, so on a long session the server's
    /// idle session would lapse before the stop-time upload.
    /// </summary>
    internal static readonly TimeSpan TouchInterval = TimeSpan.FromSeconds(240);

    /// <param name="Ok">Whether the mix path actually ran and wrote audio.</param>
    /// <param name="Detail">Human-readable diagnostics for the gate summary.</param>
    /// <param name="MicPath">Therapist (mono) PCM sidecar — what gets uploaded.</param>
    /// <param name="SystemPath">Client (stereo) PCM sidecar, when system capture ran.</param>
    /// <param name="MicRms">RMS of the mic sidecar; near zero means silence.</param>
    /// <param name="SystemRms">RMS of the system sidecar.</param>
    /// <param name="MixErrors">Mix/write cycles that threw — non-zero means audio was lost.</param>
    internal sealed record Outcome(
        bool Ok, string Detail, string MicPath, string? SystemPath,
        double MicRms, double SystemRms, long MixErrors)
    {
        /// <summary>Where the capture wrote everything; a decline must leave no audio here.</summary>
        public string Directory { get; init; } = "";

        /// <summary>The mixed recording capture writes beside the sidecars.</summary>
        public string? MixedPath { get; init; }

        /// <summary>Mix timer cycles that had audio to write.</summary>
        public long MixCycles { get; init; }

        /// <summary>Bytes handed to the writer.</summary>
        public long BytesWritten { get; init; }

        /// <summary>
        /// Real system frames dropped (late frames trimmed after silence had been
        /// padded in their place). The Windows graph buffers in growable lists, so
        /// it has no ring-buffer overflow counter like macOS; trimmed frames and
        /// failed mix cycles are the two ways it loses audio.
        /// </summary>
        public long SystemTrimmedFrames { get; init; }

        /// <summary>Silent frames padded on the system channel (reported, not gated).</summary>
        public long SystemPaddedFrames { get; init; }

        /// <summary>Samples lost: failed mix cycles plus trimmed system frames.</summary>
        public long DroppedSamples => MixErrors + SystemTrimmedFrames;

        /// <summary>
        /// The capture gate, as the macOS harness applies it. A capture that ran for
        /// <paramref name="seconds"/> must have mixed at least <c>seconds - 2</c>
        /// times (the Windows timer fires every 100 ms, so a healthy run is far
        /// above that floor; the floor catches a graph that stalled after one cycle,
        /// which used to pass), both channels must carry signal, and nothing may be
        /// dropped.
        /// </summary>
        public IReadOnlyList<Check> Checks(double seconds)
        {
            var minCycles = Math.Max(1, (long)seconds - 2);
            return
            [
                new Check(
                    "capture completed",
                    MixCycles >= minCycles && BytesWritten > 0,
                    $"mixCycles {MixCycles} (min {minCycles}), bytes {BytesWritten}"),
                new Check(
                    "per-channel audio liveness",
                    MicRms > 1 && SystemRms > 1,
                    $"mic RMS {MicRms:F0}, system RMS {SystemRms:F0}"),
                new Check(
                    "no dropped samples",
                    DroppedSamples == 0,
                    $"mix errors {MixErrors}, trimmed system frames {SystemTrimmedFrames}, "
                        + $"padded system frames {SystemPaddedFrames}"),
            ];
        }
    }

    /// <summary>
    /// Records <paramref name="seconds"/> of audio with the mic and system
    /// fixtures injected through <see cref="FileWaveIn"/>. Fixtures loop, so a
    /// short clip fills the whole capture window rather than trailing into
    /// silence — the liveness check would read that silence as a dead channel.
    /// </summary>
    /// <param name="midway">Runs halfway through, while the graph is still capturing
    /// (the visit scenario records the client's answer there, as the clinician does).
    /// If it throws, capture is stopped and the error propagates.</param>
    /// <param name="touch">Heartbeat called every <see cref="TouchInterval"/> while
    /// capturing; its failures are the caller's to swallow.</param>
    internal static async Task<Outcome> RecordAsync(
        string micFixture,
        string systemFixture,
        double seconds,
        string? outputDirectory = null,
        CancellationToken cancellationToken = default,
        Func<Task>? midway = null,
        Func<Task>? touch = null)
    {
        var tempDir = outputDirectory ?? Path.Combine(Path.GetTempPath(), $"record-{Guid.NewGuid():N}");
        System.IO.Directory.CreateDirectory(tempDir);

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

        using var keepAlive = new CancellationTokenSource();
        var heartbeat = touch is null ? Task.CompletedTask : HeartbeatAsync(touch, keepAlive.Token);

        // StartCaptureAsync only completes once stopped, so don't await it here.
        var capture = session.StartCaptureAsync();
        RecordingResult result;
        try
        {
            var half = TimeSpan.FromSeconds(seconds / 2);
            await Task.Delay(half, cancellationToken);
            if (midway is not null) await midway();
            await Task.Delay(half, cancellationToken);
        }
        catch
        {
            try { await session.StopCaptureAsync(); await capture; }
            catch (Exception stopError) { Harness.Log($"stopping capture after a failure: {stopError.Message}"); }
            keepAlive.Cancel();
            throw;
        }
        finally
        {
            keepAlive.Cancel();
            await heartbeat;
        }
        result = await session.StopCaptureAsync();
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
            MixErrors: diagnostics.MixErrors)
        {
            Directory = tempDir,
            MixedPath = string.IsNullOrEmpty(result.FilePath) ? null : result.FilePath,
            MixCycles = diagnostics.MixCycles,
            BytesWritten = diagnostics.BytesWritten,
            SystemTrimmedFrames = diagnostics.SystemTrimmedFrames,
            SystemPaddedFrames = diagnostics.SystemPaddedFrames,
        };
    }

    private static async Task HeartbeatAsync(Func<Task> touch, CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try { await Task.Delay(TouchInterval, cancellationToken); }
            catch (OperationCanceledException) { return; }
            try { await touch(); }
            catch (Exception ex) { Harness.Log($"session touch failed (ignored): {ex.Message}"); }
        }
    }

    /// <summary>File extensions capture writes audio under, encrypted or not.</summary>
    private static readonly HashSet<string> AudioExtensions =
        new(StringComparer.OrdinalIgnoreCase) { ".wav", ".pcm", ".aac", ".m4a", ".enc" };

    /// <summary>
    /// Audio files a capture left under <paramref name="directory"/> (the mixed
    /// file and its sidecars). A missing directory has none.
    /// </summary>
    internal static IReadOnlyList<string> AudioFiles(string directory) =>
        System.IO.Directory.Exists(directory)
            ? System.IO.Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories)
                .Where(f => AudioExtensions.Contains(Path.GetExtension(f)))
                .Select(Path.GetFileName)
                .OfType<string>()
                .ToList()
            : [];

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
