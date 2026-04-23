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
    public static async Task<DecryptedPcm> PrepareForUploadAsync(
        string path, AesGcmEncryptor? encryptor, CancellationToken ct = default)
    {
        var isEncrypted = path.EndsWith(".enc.pcm", StringComparison.OrdinalIgnoreCase);
        if (!isEncrypted || encryptor == null)
            return new DecryptedPcm(path, null);

        var tempPath = Path.Combine(
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
        catch { /* best-effort */ }
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
