using System.Text;
using System.Text.Json;
using AudioCapture.Storage;

namespace PabloCompanion.Services;

/// <summary>
/// Persists sessions whose audio failed to upload so uploads can be retried
/// after app restart or sign-out / sign-in. Stored as an AES-GCM-encrypted
/// JSON blob at
/// <c>%LOCALAPPDATA%\PabloCompanion\PendingTranscriptions.enc.json</c>.
///
/// Entries carry the audio file paths directly so retries don't depend on
/// <see cref="SessionRecordingStore"/>, which is wiped on sign-out.
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
    private readonly string _storePath;
    private readonly object _lock = new();
    private Dictionary<string, PendingTranscription>? _cache;

    public PendingTranscriptionStore(CredentialManager credentials) : this(credentials, StorePath) { }

    // Test hook — lets tests point at a scratch file.
    internal PendingTranscriptionStore(CredentialManager credentials, string storePath)
    {
        _credentials = credentials;
        _storePath = storePath;
    }

    public void Add(string sessionId, string micPath, string? systemPath, bool isEncrypted)
    {
        lock (_lock)
        {
            var store = Load();
            store[sessionId] = new PendingTranscription(
                SessionId: sessionId,
                MicPath: micPath,
                SystemPath: systemPath,
                IsEncrypted: isEncrypted,
                CreatedAt: DateTime.UtcNow,
                RetryCount: 0);
            Persist(store);
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
            if (File.Exists(_storePath))
                File.Delete(_storePath);
        }
    }

    private Dictionary<string, PendingTranscription> Load()
    {
        if (_cache != null) return _cache;

        if (!File.Exists(_storePath))
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

            var fileBytes = File.ReadAllBytes(_storePath);
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

        var dir = Path.GetDirectoryName(_storePath);
        if (!string.IsNullOrEmpty(dir))
            Directory.CreateDirectory(dir);

        var key = _credentials.GetOrCreateUserEncryptionKey();
        if (key == null) return;

        var json = JsonSerializer.Serialize(store, JsonOptions);
        var plaintext = Encoding.UTF8.GetBytes(json);
        using var encryptor = new AesGcmEncryptor(key, "device-key");
        var encrypted = encryptor.Encrypt(plaintext);
        File.WriteAllBytes(_storePath, encrypted);
    }
}

public sealed record PendingTranscription(
    string SessionId,
    string MicPath,
    string? SystemPath,
    bool IsEncrypted,
    DateTime CreatedAt,
    int RetryCount);
