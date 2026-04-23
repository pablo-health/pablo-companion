using AudioCapture.Capture;
using AudioCapture.Interfaces;
using AudioCapture.Models;
using AudioCapture.Storage;
using PabloCompanion.Models;

namespace PabloCompanion.Services;

/// <summary>
/// Wraps AudioCapture's WasapiCaptureSession for use in Pablo Companion.
/// Manages capture lifecycle, encryption key sourcing, and output directory.
/// </summary>
public sealed class RecordingService : IDisposable
{
    private readonly CredentialManager _credentials;
    private WasapiCaptureSession? _session;
    private CaptureConfiguration? _activeConfig;
    private string? _activeSessionId;

    public RecordingService(CredentialManager credentials)
    {
        _credentials = credentials;
    }

    public bool IsRecording => _session?.State.Kind == CaptureStateKind.Capturing
                            || _session?.State.Kind == CaptureStateKind.Paused;

    public AudioLevels GetCurrentLevels() =>
        _session?.CurrentLevels ?? AudioLevels.Zero;

    /// <summary>
    /// Starts recording for the given session. Returns when recording finishes (via StopAsync).
    /// </summary>
    public async Task<LocalRecording> StartAsync(string sessionId, string? micDeviceId = null,
        MixingStrategy mixingStrategy = MixingStrategy.Blended, bool exportRawPcm = false)
    {
        if (_session != null)
            throw new InvalidOperationException("A recording is already active.");

        _activeSessionId = sessionId;

        var outputDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "PabloCompanion", "Recordings", sessionId);

        // Get or create encryption key
        var keyBytes = _credentials.GetOrCreateUserEncryptionKey();
        ICaptureEncryptor? encryptor = keyBytes != null
            ? new AesGcmEncryptor(keyBytes, "device-key")
            : null;

        _activeConfig = new CaptureConfiguration
        {
            SampleRate = 48000,
            BitDepth = 16,
            Channels = 2,
            Encryptor = encryptor,
            OutputDirectory = outputDir,
            MicDeviceId = micDeviceId,
            EnableMicCapture = true,
            EnableSystemCapture = true,
            MixingStrategy = mixingStrategy,
            ExportRawPcm = exportRawPcm,
        };

        _session = new WasapiCaptureSession();
        _session.Configure(_activeConfig);
        var result = await _session.StartCaptureAsync();

        return ToLocalRecording(result);
    }

    public async Task<LocalRecording> StopAsync()
    {
        if (_session == null)
            throw new InvalidOperationException("No active recording.");

        var result = await _session.StopCaptureAsync();
        Cleanup();
        return ToLocalRecording(result);
    }

    public void Pause()
    {
        _session?.PauseCapture();
    }

    public void Resume()
    {
        _session?.ResumeCapture();
    }

    public Task<AudioSource[]> GetAvailableDevicesAsync()
    {
        using var session = new WasapiCaptureSession();
        return session.GetAvailableAudioSourcesAsync();
    }

    public void Dispose()
    {
        Cleanup();
    }

    private void Cleanup()
    {
        _session?.Dispose();
        _session = null;
        _activeConfig = null;
        _activeSessionId = null;
    }

    private static LocalRecording ToLocalRecording(RecordingResult result)
    {
        return new LocalRecording(
            Id: result.Metadata.Id,
            FilePath: result.FilePath,
            Duration: result.DurationSecs,
            CreatedAt: result.Metadata.CreatedAt,
            IsEncrypted: result.Metadata.IsEncrypted,
            Checksum: result.Checksum,
            ChannelLayout: result.Metadata.ChannelLayout,
            MicPcmFilePath: result.RawPcmFilePaths.Length > 0 ? result.RawPcmFilePaths[0] : null,
            SystemPcmFilePath: result.RawPcmFilePaths.Length > 1 ? result.RawPcmFilePaths[1] : null,
            IsUploaded: false);
    }
}
