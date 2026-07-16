using AudioCapture.Storage;
using PabloCompanion.Services;

namespace PabloCompanion.Tests.Services;

/// <summary>
/// Covers the seam between an encrypted sidecar on disk and the uploader.
///
/// The uploader cannot tell audio from ciphertext — it stamps a WAV header on
/// whatever path it is handed. So this class is the only thing standing between a
/// missing key and a session's audio being replaced by noise on the backend, with
/// the local recovery record deleted on the resulting 200. That makes "fail closed"
/// a guarantee worth pinning rather than an implementation detail.
/// </summary>
public class PcmDecryptorTests : IDisposable
{
    private readonly string _tempDir;

    public PcmDecryptorTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), $"pcmdec_test_{Guid.NewGuid():N}");
        Directory.CreateDirectory(_tempDir);
    }

    public void Dispose()
    {
        GC.SuppressFinalize(this);
        if (Directory.Exists(_tempDir))
            Directory.Delete(_tempDir, recursive: true);
    }

    private static AesGcmEncryptor Encryptor() => new(new byte[32], "test-key");

    /// <summary>Writes an encrypted sidecar in the [4-byte LE length][sealed box] chunk format.</summary>
    private string WriteEncryptedSidecar(string name, byte[] plaintext)
    {
        var path = Path.Combine(_tempDir, name);
        var sealedBox = Encryptor().Encrypt(plaintext);

        using var stream = File.Create(path);
        stream.Write(BitConverter.GetBytes((uint)sealedBox.Length));
        stream.Write(sealedBox);
        return path;
    }

    private string WritePlainSidecar(string name, byte[] contents)
    {
        var path = Path.Combine(_tempDir, name);
        File.WriteAllBytes(path, contents);
        return path;
    }

    [Fact]
    public async Task EncryptedSidecarWithoutAKey_ThrowsRatherThanReturningCiphertext()
    {
        // The regression that matters. Returning the path here would upload AES-GCM
        // ciphertext as if it were audio: the backend accepts it, the caller sees a
        // 200 and deletes its recovery record, and the session is gone while the
        // therapist is told the upload succeeded.
        var encrypted = WriteEncryptedSidecar("recording_mic.enc.pcm", [1, 2, 3, 4]);

        var ex = await Assert.ThrowsAsync<InvalidOperationException>(
            () => PcmDecryptor.PrepareForUploadAsync(encrypted, encryptor: null));

        Assert.Contains("no encryption key", ex.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task EncryptedSidecarWithAKey_DecryptsToATempFile()
    {
        var plaintext = new byte[] { 9, 8, 7, 6, 5 };
        var encrypted = WriteEncryptedSidecar("recording_mic.enc.pcm", plaintext);

        using var prepared = await PcmDecryptor.PrepareForUploadAsync(encrypted, Encryptor());

        Assert.NotNull(prepared.TempFile);
        Assert.NotEqual(encrypted, prepared.Path);
        Assert.Equal(plaintext, await File.ReadAllBytesAsync(prepared.Path));
    }

    [Fact]
    public async Task PlaintextSidecarWithoutAKey_IsPassedThroughUntouched()
    {
        // An unencrypted sidecar has no key to be missing — this path must keep
        // working, or the fail-closed check would break every non-encrypted upload.
        var plain = WritePlainSidecar("recording_mic.pcm", [1, 2, 3]);

        using var prepared = await PcmDecryptor.PrepareForUploadAsync(plain, encryptor: null);

        Assert.Equal(plain, prepared.Path);
        Assert.Null(prepared.TempFile);
    }

    [Fact]
    public async Task PreparedTempFile_IsDeletedOnDispose()
    {
        // The temp file holds decrypted PHI, so it must not outlive the upload.
        var encrypted = WriteEncryptedSidecar("recording_mic.enc.pcm", [1, 2, 3, 4]);

        string tempPath;
        using (var prepared = await PcmDecryptor.PrepareForUploadAsync(encrypted, Encryptor()))
        {
            tempPath = prepared.Path;
            Assert.True(File.Exists(tempPath));
        }

        Assert.False(File.Exists(tempPath), "decrypted PHI temp file outlived the upload");
    }
}
