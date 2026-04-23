using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using AudioCapture.Storage;

namespace PabloCompanion.Services;

/// <summary>
/// Persists pending transcription/upload work as AES-GCM-encrypted JSON.
/// Survives app restarts so transcription and uploads can resume.
/// File: %LOCALAPPDATA%\PabloCompanion\PendingTranscriptions.enc.json
/// </summary>
public sealed class PendingTranscriptionStore
{
    private static readonly string StorePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "PabloCompanion", "PendingTranscriptions.enc.json");

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = false,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    private readonly CredentialManager _credentials;
    private readonly object _lock = new();
    private Dictionary<string, PendingTranscription>? _cache;

    public PendingTranscriptionStore(CredentialManager credentials)
    {
        _credentials = credentials;
    }

    public void Add(string sessionId, QualityPreset preset)
    {
        lock (_lock)
        {
            var store = Load();
            store[sessionId] = new PendingTranscription(sessionId, null, preset, DateTime.UtcNow, 0);
            Persist(store);
        }
    }

    public void UpdateWithTranscript(string sessionId, string transcriptText)
    {
        lock (_lock)
        {
            var store = Load();
            if (store.TryGetValue(sessionId, out var existing))
            {
                store[sessionId] = existing with { TranscriptText = transcriptText };
                Persist(store);
            }
        }
    }

    public void IncrementRetry(string sessionId)
    {
        lock (_lock)
        {
            var store = Load();
            if (store.TryGetValue(sessionId, out var existing))
            {
                store[sessionId] = existing with { RetryCount = existing.RetryCount + 1 };
                Persist(store);
            }
        }
    }

    public void Remove(string sessionId)
    {
        lock (_lock)
        {
            var store = Load();
            if (store.Remove(sessionId))
                Persist(store);
        }
    }

    public PendingTranscription[] GetAll()
    {
        lock (_lock)
        {
            return [.. Load().Values];
        }
    }

    public PendingTranscription? Get(string sessionId)
    {
        lock (_lock)
        {
            return Load().GetValueOrDefault(sessionId);
        }
    }

    public void Clear()
    {
        lock (_lock)
        {
            _cache = [];
            if (File.Exists(StorePath))
                File.Delete(StorePath);
        }
    }

    private Dictionary<string, PendingTranscription> Load()
    {
        if (_cache != null) return _cache;

        if (!File.Exists(StorePath))
        {
            _cache = [];
            return _cache;
        }

        try
        {
            var key = _credentials.GetOrCreateUserEncryptionKey();
            if (key == null)
            {
                _cache = [];
                return _cache;
            }

            var fileBytes = File.ReadAllBytes(StorePath);
            using var encryptor = new AesGcmEncryptor(key, "device-key");
            var decrypted = encryptor.Decrypt(fileBytes);
            var json = Encoding.UTF8.GetString(decrypted);
            _cache = JsonSerializer.Deserialize<Dictionary<string, PendingTranscription>>(json, JsonOptions) ?? [];
        }
        catch
        {
            _cache = [];
        }

        return _cache;
    }

    private void Persist(Dictionary<string, PendingTranscription> store)
    {
        _cache = store;

        var dir = Path.GetDirectoryName(StorePath);
        if (!string.IsNullOrEmpty(dir))
            Directory.CreateDirectory(dir);

        var key = _credentials.GetOrCreateUserEncryptionKey();
        if (key == null) return;

        var json = JsonSerializer.Serialize(store, JsonOptions);
        var plaintext = Encoding.UTF8.GetBytes(json);
        using var encryptor = new AesGcmEncryptor(key, "device-key");
        var encrypted = encryptor.Encrypt(plaintext);
        File.WriteAllBytes(StorePath, encrypted);
    }
}

public sealed record PendingTranscription(
    string SessionId,
    string? TranscriptText,
    QualityPreset Preset,
    DateTime CreatedAt,
    int RetryCount);
