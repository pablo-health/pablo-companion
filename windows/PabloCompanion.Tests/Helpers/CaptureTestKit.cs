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

    public static FailableWaveIn Mic() => Mic(48000);

    /// <summary>A mono 16-bit mic delivering at <paramref name="sampleRate"/>, e.g. 16 kHz like a hands-free headset.</summary>
    public static FailableWaveIn Mic(int sampleRate) =>
        new(SignalGeneratorWaveIn.Mono16(new SignalGeneratorWaveIn.MarkerTone(440, 880, 1.0), sampleRate));

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
/// root, keeping hold of every capture session, mic and system source it builds.
/// </summary>
internal sealed class CaptureRig : IDisposable
{
    private readonly List<FailableWaveIn> _systems = [];

    public CaptureRig(byte[]? key)
    {
        Root = Path.Join(Path.GetTempPath(), $"pablo-rec-{Guid.NewGuid():N}");
        Credentials = new KeyCredentialManager(key);
        Service = new RecordingService(Credentials, Root, () =>
        {
            var mic = MicSource();
            Mics.Add(mic);
            var session = new WasapiCaptureSession(() => mic, NewSystem);
            Sessions.Add(session);
            return session;
        });
    }

    /// <summary>
    /// Builds the mic for each new capture: the stand-in for whichever device is the
    /// default when a capture starts. Swap it to change the default between captures.
    /// </summary>
    public Func<FailableWaveIn> MicSource { get; set; } = FailableWaveIn.Mic;

    /// <summary>
    /// Every system source handed out, in order. A capture following the default
    /// output builds a new one each time it re-opens system audio, on its own thread.
    /// </summary>
    public FailableWaveIn[] Systems
    {
        get
        {
            lock (_systems) return [.. _systems];
        }
    }

    private FailableWaveIn NewSystem()
    {
        var system = FailableWaveIn.System();
        lock (_systems) _systems.Add(system);
        return system;
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
