using System.Buffers.Binary;
using AudioCapture.Storage;
using PabloCompanion.Models;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Storage;

namespace PabloCompanion.Services;

/// <summary>
/// Decrypts encrypted WAV recordings and plays them via Windows MediaPlayer.
/// WAV format: [44-byte header (plaintext)][4-byte LE len | nonce|ciphertext|tag]...
/// Decrypts to a temp WAV file, plays via MediaPlayer with position/duration tracking.
/// </summary>
public sealed class PlaybackService : IDisposable
{
    private readonly CredentialManager _credentials;
    private MediaPlayer? _player;
    private string? _tempFilePath;

    public string? PlayingSessionId { get; private set; }
    public bool IsPlaying => _player?.PlaybackSession?.PlaybackState == MediaPlaybackState.Playing;
    public bool IsPaused => _player?.PlaybackSession?.PlaybackState == MediaPlaybackState.Paused;
    public bool IsActive => _player != null && PlayingSessionId != null;

    public TimeSpan Position
    {
        get => _player?.PlaybackSession?.Position ?? TimeSpan.Zero;
        set { if (_player?.PlaybackSession != null) _player.PlaybackSession.Position = value; }
    }

    public TimeSpan Duration => _player?.PlaybackSession?.NaturalDuration ?? TimeSpan.Zero;

    public event EventHandler? PlaybackStateChanged;
    public event EventHandler? PlaybackEnded;

    public PlaybackService(CredentialManager credentials)
    {
        _credentials = credentials;
    }

    public async Task PlayAsync(LocalRecording recording, string sessionId)
    {
        Stop();

        var decryptedPath = await DecryptWavToTempFileAsync(recording);

        var file = await StorageFile.GetFileFromPathAsync(decryptedPath);
        var source = MediaSource.CreateFromStorageFile(file);

        _player = new MediaPlayer { Source = source };
        _player.PlaybackSession.PlaybackStateChanged += (s, _) =>
            PlaybackStateChanged?.Invoke(this, EventArgs.Empty);
        _player.MediaEnded += (s, _) =>
        {
            PlaybackEnded?.Invoke(this, EventArgs.Empty);
        };

        PlayingSessionId = sessionId;
        _player.Play();
    }

    public void Pause()
    {
        _player?.Pause();
    }

    public void Resume()
    {
        _player?.Play();
    }

    public void Stop()
    {
        if (_player != null)
        {
            _player.Pause();
            _player.Source = null;
            _player.Dispose();
            _player = null;
        }

        PlayingSessionId = null;
        CleanupTempFile();
    }

    public void Seek(TimeSpan position)
    {
        if (_player?.PlaybackSession != null)
            _player.PlaybackSession.Position = position;
    }

    /// <summary>
    /// Decrypt encrypted WAV: read 44-byte header, decrypt length-prefixed chunks, write clean WAV.
    /// </summary>
    private async Task<string> DecryptWavToTempFileAsync(LocalRecording recording)
    {
        var fileBytes = await File.ReadAllBytesAsync(recording.FilePath);

        if (!recording.IsEncrypted)
        {
            // Unencrypted — use directly
            _tempFilePath = recording.FilePath;
            return _tempFilePath;
        }

        var key = _credentials.GetOrCreateUserEncryptionKey()
            ?? throw new InvalidOperationException("No encryption key available");

        using var encryptor = new AesGcmEncryptor(key, "device-key");

        // Read 44-byte WAV header (plaintext)
        if (fileBytes.Length < 44)
            throw new InvalidOperationException("File too small to contain WAV header");

        var header = fileBytes.AsSpan(0, 44).ToArray();

        // Decrypt all data chunks
        using var pcmData = new MemoryStream();
        int offset = 44;

        while (offset + 4 <= fileBytes.Length)
        {
            uint chunkLength = BinaryPrimitives.ReadUInt32LittleEndian(fileBytes.AsSpan(offset, 4));
            offset += 4;

            if (offset + (int)chunkLength > fileBytes.Length)
                break;

            var encryptedChunk = new byte[chunkLength];
            Buffer.BlockCopy(fileBytes, offset, encryptedChunk, 0, (int)chunkLength);
            offset += (int)chunkLength;

            var decrypted = encryptor.Decrypt(encryptedChunk);
            pcmData.Write(decrypted, 0, decrypted.Length);
        }

        // Build clean WAV with correct header sizes
        var pcmBytes = pcmData.ToArray();
        var cleanHeader = PatchWavHeader(header, (uint)pcmBytes.Length);

        // Write to temp file
        _tempFilePath = Path.Combine(Path.GetTempPath(), $"pablo_playback_{Guid.NewGuid():N}.wav");
        using (var fs = new FileStream(_tempFilePath, FileMode.Create, FileAccess.Write))
        {
            await fs.WriteAsync(cleanHeader);
            await fs.WriteAsync(pcmBytes);
        }

        return _tempFilePath;
    }

    /// <summary>
    /// Patch WAV header with correct RIFF chunk size and data sub-chunk size.
    /// </summary>
    private static byte[] PatchWavHeader(byte[] header, uint dataSize)
    {
        var patched = (byte[])header.Clone();

        // RIFF chunk size at offset 4 = file size - 8
        BinaryPrimitives.WriteUInt32LittleEndian(patched.AsSpan(4, 4), 36 + dataSize);

        // data sub-chunk size at offset 40
        BinaryPrimitives.WriteUInt32LittleEndian(patched.AsSpan(40, 4), dataSize);

        return patched;
    }

    private void CleanupTempFile()
    {
        if (_tempFilePath != null && File.Exists(_tempFilePath) &&
            _tempFilePath.StartsWith(Path.GetTempPath(), StringComparison.OrdinalIgnoreCase))
        {
            try { File.Delete(_tempFilePath); } catch { }
        }
        _tempFilePath = null;
    }

    public void Dispose()
    {
        Stop();
    }
}
