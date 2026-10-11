using System.Security.Cryptography;
using AudioCapture.Capture;
using AudioCapture.Models;
using AudioCapture.Storage;

namespace PabloCompanion.Services;

/// <summary>The capture the audio check listens through.</summary>
public interface IAudioCheckCapture
{
    /// <summary>Starts capturing; throws when the capture can't start.</summary>
    Task StartAsync(string? micDeviceId);

    /// <summary>The latest linear RMS levels (0-1).</summary>
    AudioLevels CurrentLevels { get; }

    /// <summary>
    /// Stops capture (if running) and deletes everything it wrote. Safe to call
    /// more than once, and after a failed start.
    /// </summary>
    Task FinishAsync();
}

/// <summary>
/// Runs the real capture graph for the first-use audio check, keeping nothing.
/// Mirrors <c>AudioCheckCapture.swift</c>.
///
/// AudioCaptureKit always writes to a directory, so the check records into a
/// fresh temp folder, sealed with a key that exists only in memory, and the
/// folder is deleted when the check ends. Same capture path as a session
/// (which is the point of the check) without leaving audio behind.
/// </summary>
public sealed class AudioCheckCapture : IAudioCheckCapture
{
    private readonly Func<WasapiCaptureSession> _sessionFactory;
    private WasapiCaptureSession? _session;
    private AesGcmEncryptor? _encryptor;
    private Task? _capture;

    public AudioCheckCapture()
        : this(() => new WasapiCaptureSession())
    {
    }

    /// <summary>Test seam: injected sources in place of the WASAPI endpoints.</summary>
    internal AudioCheckCapture(Func<WasapiCaptureSession> sessionFactory)
    {
        _sessionFactory = sessionFactory;
        Directory = Path.Join(Path.GetTempPath(), $"pablo-audio-check-{Guid.NewGuid():N}");
    }

    /// <summary>The temp folder the check records into; gone after <see cref="FinishAsync"/>.</summary>
    public string Directory { get; }

    public AudioLevels CurrentLevels => _session?.CurrentLevels ?? AudioLevels.Zero;

    public Task StartAsync(string? micDeviceId)
    {
        System.IO.Directory.CreateDirectory(Directory);

        // AES-GCM with a random key that never leaves memory: whatever the check
        // writes is unreadable by the time the folder is deleted, and even if it
        // weren't deleted.
        var key = RandomNumberGenerator.GetBytes(32);
        _encryptor = new AesGcmEncryptor(key, "audio-check-throwaway");
        CryptographicOperations.ZeroMemory(key);

        var config = new CaptureConfiguration
        {
            SampleRate = 48000,
            BitDepth = 16,
            Channels = 2,
            Encryptor = _encryptor,
            OutputDirectory = Directory,
            MicDeviceId = micDeviceId,
            EnableMicCapture = true,
            EnableSystemCapture = true,
            MixingStrategy = MixingStrategy.Separated,
            ExportRawPcm = false,
            // The check listens where the greeting plays: the default output,
            // the same endpoint a session's loopback follows.
            FollowDefaultOutputDevice = true,
        };

        var session = _sessionFactory();
        _session = session;
        session.Configure(config);

        // StartCaptureAsync runs synchronously until the capture is live and then
        // waits for the stop, so on return it has either failed or is capturing.
        var capture = session.StartCaptureAsync();
        if (capture.IsCompleted)
            capture.GetAwaiter().GetResult();
        if (session.State.Kind != CaptureStateKind.Capturing)
            throw CaptureException.Unknown($"Capture did not start (state {session.State.Kind}).");
        _capture = capture.ContinueWith(
            t => _ = t.Exception,
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
        return Task.CompletedTask;
    }

    public async Task FinishAsync()
    {
        var session = _session;
        _session = null;
        if (session is not null)
        {
            try
            {
                if (session.State.Kind is CaptureStateKind.Capturing or CaptureStateKind.Paused)
                    await session.StopCaptureAsync().ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                App.Log($"AudioCheck: stop failed type={ex.GetType().Name}");
            }
            session.Dispose();
        }
        _capture = null;
        _encryptor?.Dispose();
        _encryptor = null;

        try
        {
            if (System.IO.Directory.Exists(Directory))
                System.IO.Directory.Delete(Directory, recursive: true);
        }
        catch (IOException ex)
        {
            App.Log($"AudioCheck: temp folder not deleted type={ex.GetType().Name}");
        }
        catch (UnauthorizedAccessException ex)
        {
            App.Log($"AudioCheck: temp folder not deleted type={ex.GetType().Name}");
        }
    }
}
