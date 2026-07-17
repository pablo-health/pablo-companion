using System.Buffers.Binary;
using AudioCapture.Storage;

namespace PabloCompanion.Services;

/// <summary>
/// Decrypts AES-GCM encrypted PCM sidecars to plaintext temp files so they can
/// be streamed directly in a multipart upload. Mirrors
/// `RecordingEncryptor.decryptPCMToTempFile` on macOS.
///
/// Encrypted format per chunk: <c>[4-byte LE length][nonce|ciphertext|tag]</c>.
/// </summary>
public static class PcmDecryptor
{
    /// <summary>
    /// If <paramref name="path"/> ends in <c>.enc.pcm</c>, decrypts it to a
    /// temp file and returns the temp path plus a disposable cleanup handle.
    /// Otherwise returns the original path with a no-op cleanup.
    /// </summary>
    /// <exception cref="InvalidOperationException">
    /// The sidecar is encrypted but no <paramref name="encryptor"/> was supplied.
    /// </exception>
    public static async Task<DecryptedPcm> PrepareForUploadAsync(
        string path, AesGcmEncryptor? encryptor, CancellationToken ct = default)
    {
        var isEncrypted = path.EndsWith(".enc.pcm", StringComparison.OrdinalIgnoreCase);
        if (!isEncrypted)
            return new DecryptedPcm(path, null);

        // Fail closed. Returning the path unchanged here would hand raw AES-GCM
        // ciphertext to the uploader, which has no way to know it isn't audio: it
        // would stamp a WAV header on it, the backend would accept it, and the
        // caller would delete its only recovery record on the 200. The session's
        // audio would be gone, and the therapist would be told it uploaded. A
        // missing key is a transient, recoverable state (see
        // CredentialManager.GetOrCreateUserEncryptionKey, whose own contract says
        // callers must treat null as "no key available") — so it must surface as a
        // failure the retry path can hold onto, never as a successful upload.
        if (encryptor == null)
        {
            throw new InvalidOperationException(
                "Cannot decrypt an encrypted recording for upload: no encryption key is available. "
                    + "The recording stays queued and will retry once a key can be resolved.");
        }

        var tempPath = Path.Join(
            Path.GetTempPath(),
            $"pablo-upload-{Guid.NewGuid():N}.pcm");

        try
        {
            await DecryptToFileAsync(path, tempPath, encryptor, ct);
        }
        catch
        {
            TryDelete(tempPath);
            throw;
        }

        return new DecryptedPcm(tempPath, tempPath);
    }

    private static async Task DecryptToFileAsync(
        string sourcePath, string destPath, AesGcmEncryptor encryptor, CancellationToken ct)
    {
        var fileBytes = await File.ReadAllBytesAsync(sourcePath, ct);
        await using var output = File.Create(destPath);

        int offset = 0;
        while (offset + 4 <= fileBytes.Length)
        {
            uint chunkLength = BinaryPrimitives.ReadUInt32LittleEndian(fileBytes.AsSpan(offset, 4));
            offset += 4;
            if (offset + (int)chunkLength > fileBytes.Length) break;

            var encryptedChunk = new byte[chunkLength];
            Buffer.BlockCopy(fileBytes, offset, encryptedChunk, 0, (int)chunkLength);
            offset += (int)chunkLength;

            var decrypted = encryptor.Decrypt(encryptedChunk);
            await output.WriteAsync(decrypted, ct);
        }
    }

    internal static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch (IOException) { /* best-effort cleanup */ }
        catch (UnauthorizedAccessException) { /* best-effort cleanup */ }
    }
}

/// <summary>
/// Pair of (path-to-upload, optional-temp-file-to-delete).
/// <see cref="Dispose"/> deletes the temp file when present.
/// </summary>
public readonly record struct DecryptedPcm(string Path, string? TempFile) : IDisposable
{
    public void Dispose()
    {
        if (TempFile != null) PcmDecryptor.TryDelete(TempFile);
    }
}
