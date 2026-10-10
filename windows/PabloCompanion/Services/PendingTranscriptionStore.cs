using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
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

    /// <summary>
    /// Failed attempts after which an entry stops being retried automatically and
    /// reads as a permanent failure. Matches macOS
    /// (<c>PendingAudioUploadCoordinator.Policy.maxAutoRetries</c>). The manual
    /// "Retry now" still tries it.
    /// </summary>
    public const int MaxAutoRetries = 10;

    /// <param name="sampleRate">
    /// Rate the sidecars were captured at, stamped into the WAV header at upload.
    /// Null falls back to 48 kHz when the upload runs.
    /// </param>
    public void Add(string sessionId, string micPath, string? systemPath, bool isEncrypted, int? sampleRate = null)
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
                RetryCount: 0,
                SampleRate: sampleRate);
            Persist(store);
        }
    }

    /// <summary>
    /// Record a failed attempt: increment the retry count and stamp
    /// <see cref="PendingTranscription.LastAttemptAt"/>, which the backoff ladder
    /// counts from. No-op if the entry is gone.
    /// </summary>
    public void IncrementRetry(string sessionId, DateTime? at = null)
    {
        lock (_lock)
        {
            var store = Load();
            if (store.TryGetValue(sessionId, out var existing))
            {
                store[sessionId] = existing with
                {
                    RetryCount = existing.RetryCount + 1,
                    LastAttemptAt = at ?? DateTime.UtcNow,
                };
                Persist(store);
            }
        }
    }

    /// <summary>
    /// Move an entry through the upload → note lifecycle (e.g. to
    /// <see cref="UploadLifecycleState.AwaitingNote"/> once its upload lands).
    /// Persisted so a therapist who closes the app mid-transcription resumes
    /// reconciliation on the next launch rather than losing the audio.
    /// </summary>
    public void SetState(string sessionId, UploadLifecycleState state)
    {
        lock (_lock)
        {
            var store = Load();
            if (store.TryGetValue(sessionId, out var existing))
            {
                store[sessionId] = existing with { State = state };
                Persist(store);
            }
        }
    }

    /// <summary>
    /// Reset the retry counter to zero. Used when a re-queued upload should
    /// start the backoff ladder fresh rather than inherit the old count.
    /// </summary>
    public void ResetRetry(string sessionId)
    {
        lock (_lock)
        {
            var store = Load();
            if (store.TryGetValue(sessionId, out var existing))
            {
                store[sessionId] = existing with { RetryCount = 0 };
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
    int RetryCount,
    // Optional-with-default: entries written before this field existed have no
    // `state` in their JSON and decode as PendingUpload — the old behaviour —
    // rather than failing to deserialize and dropping a queued upload.
    UploadLifecycleState State = UploadLifecycleState.PendingUpload,
    // When the last failed attempt happened; the backoff ladder counts from here.
    // Optional so entries written before it existed still decode - those fall
    // back to CreatedAt, the old anchor, which made every tick "due" once an
    // entry was older than its backoff.
    DateTime? LastAttemptAt = null,
    // Capture rate of the sidecars, stamped into the WAV header at upload.
    // Optional so older entries still decode; null falls back to 48 kHz, which
    // is what every upload used before this field existed. Raw PCM carries no
    // header to recover the true rate from.
    int? SampleRate = null)
{
    /// <summary>The moment the backoff ladder counts from.</summary>
    [JsonIgnore]
    public DateTime BackoffAnchor => LastAttemptAt ?? CreatedAt;

    /// <summary>
    /// The entry has failed <see cref="PendingTranscriptionStore.MaxAutoRetries"/>
    /// times and is no longer retried automatically - for example a queued entry
    /// whose audio file is gone, which fails the same way on every attempt.
    /// Derived from the retry count, so no new state is persisted.
    /// </summary>
    [JsonIgnore]
    public bool IsPermanentlyFailed => RetryCount >= PendingTranscriptionStore.MaxAutoRetries;
}
