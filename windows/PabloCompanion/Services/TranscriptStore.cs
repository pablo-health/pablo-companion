using System.Text;
using AudioCapture.Storage;

namespace PabloCompanion.Services;

/// <summary>
/// Persists rendered transcript text per session as AES-GCM-encrypted files.
/// Files stored at %LOCALAPPDATA%\PabloCompanion\Transcripts\{sessionId}.enc
/// </summary>
public sealed class TranscriptStore
{
    private static readonly string StoreDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "PabloCompanion", "Transcripts");

    private readonly CredentialManager _credentials;

    public TranscriptStore(CredentialManager credentials)
    {
        _credentials = credentials;
    }

    public void Save(string sessionId, string text)
    {
        var key = _credentials.GetOrCreateDeviceEncryptionKey();
        if (key == null) return;

        Directory.CreateDirectory(StoreDir);
        var plaintext = Encoding.UTF8.GetBytes(text);
        using var encryptor = new AesGcmEncryptor(key, "device-key");
        var encrypted = encryptor.Encrypt(plaintext);
        File.WriteAllBytes(GetPath(sessionId), encrypted);
    }

    public string? Get(string sessionId)
    {
        var path = GetPath(sessionId);
        if (!File.Exists(path)) return null;

        var key = _credentials.GetOrCreateDeviceEncryptionKey();
        if (key == null) return null;

        try
        {
            var encrypted = File.ReadAllBytes(path);
            using var encryptor = new AesGcmEncryptor(key, "device-key");
            var decrypted = encryptor.Decrypt(encrypted);
            return Encoding.UTF8.GetString(decrypted);
        }
        catch
        {
            return null;
        }
    }

    public void Remove(string sessionId)
    {
        var path = GetPath(sessionId);
        if (File.Exists(path))
            File.Delete(path);
    }

    public void Clear()
    {
        if (Directory.Exists(StoreDir))
            Directory.Delete(StoreDir, recursive: true);
    }

    private static string GetPath(string sessionId) =>
        Path.Combine(StoreDir, $"{sessionId}.enc");
}
