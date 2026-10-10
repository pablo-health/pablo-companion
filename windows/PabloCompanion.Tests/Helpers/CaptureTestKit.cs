using System.Security.Cryptography;
using AudioCapture.Capture;
using NAudio.Wave;
using PabloCompanion.Services;

namespace PabloCompanion.Tests.Helpers;

/// <summary>Hands out a fixed key, or none at all (the fail-closed case).</summary>
internal sealed class KeyCredentialManager(byte[]? key) : CredentialManager
{
    public static byte[] NewKey() => RandomNumberGenerator.GetBytes(32);

    /// <summary>The key handed out; null makes every capture start fail closed.</summary>
    public byte[]? Key { get; set; } = key;

    public override byte[]? GetOrCreateUserEncryptionKey() => Key;
}

/// <summary>
/// A tone source that can die the way a real WASAPI mic does: it stops and
/// raises <see cref="RecordingStopped"/> carrying the exception.
/// </summary>
internal sealed class FailableWaveIn : IWaveIn
{
    private readonly SignalGeneratorWaveIn _inner;

    public FailableWaveIn(SignalGeneratorWaveIn inner)
    {
        _inner = inner;
        _inner.DataAvailable += (s, e) =>
        {
            if (!Muted) DataAvailable?.Invoke(this, e);
        };
        _inner.RecordingStopped += (s, e) => RecordingStopped?.Invoke(this, e);
    }

    public static FailableWaveIn Mic() =>
        new(SignalGeneratorWaveIn.Mono16(new SignalGeneratorWaveIn.MarkerTone(440, 880, 1.0)));

    public static FailableWaveIn System() =>
        new(SignalGeneratorWaveIn.StereoFloat(new SignalGeneratorWaveIn.MarkerTone(300, 600, 1.0)));

    public event EventHandler<WaveInEventArgs>? DataAvailable;

    /// <summary>
    /// Keeps running but delivers nothing: the silent WASAPI death the watchdog
    /// exists for. The mic is the capture's clock, so its sidecar stops growing.
    /// </summary>
    public volatile bool Muted;

    public event EventHandler<StoppedEventArgs>? RecordingStopped;

    public WaveFormat WaveFormat
    {
        get => _inner.WaveFormat;
        set => _inner.WaveFormat = value;
    }

    public void StartRecording() => _inner.StartRecording();

    public void StopRecording() => _inner.StopRecording();

    /// <summary>The device went away mid-capture.</summary>
    public void Fail(Exception error)
    {
        _inner.StopRecording();
        RecordingStopped?.Invoke(this, new StoppedEventArgs(error));
    }

    public void Dispose() => _inner.Dispose();
}

/// <summary>
/// A <see cref="RecordingService"/> over injected sources in a temp recordings
/// root, keeping hold of every capture session and mic it builds.
/// </summary>
internal sealed class CaptureRig : IDisposable
{
    public CaptureRig(byte[]? key)
    {
        Root = Path.Join(Path.GetTempPath(), $"pablo-rec-{Guid.NewGuid():N}");
        Credentials = new KeyCredentialManager(key);
        Service = new RecordingService(Credentials, Root, () =>
        {
            var mic = FailableWaveIn.Mic();
            Mics.Add(mic);
            var session = new WasapiCaptureSession(() => mic, FailableWaveIn.System);
            Sessions.Add(session);
            return session;
        });
    }

    public string Root { get; }

    public KeyCredentialManager Credentials { get; }

    public byte[]? Key => Credentials.Key;

    public RecordingService Service { get; }

    public List<WasapiCaptureSession> Sessions { get; } = [];

    public List<FailableWaveIn> Mics { get; } = [];

    public void Dispose()
    {
        Service.Dispose();
        try { if (Directory.Exists(Root)) Directory.Delete(Root, recursive: true); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}

internal static class Eventually
{
    /// <summary>Polls until <paramref name="condition"/> holds, or fails after <paramref name="timeout"/>.</summary>
    public static async Task TrueAsync(Func<bool> condition, TimeSpan timeout, string because)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (!condition())
        {
            if (DateTime.UtcNow > deadline)
                Assert.Fail($"Timed out after {timeout.TotalMilliseconds} ms waiting for: {because}");
            await Task.Delay(20);
        }
    }
}
