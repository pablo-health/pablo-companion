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
    // The key the cache was decrypted with. The cache is only trusted while the
    // signed-in user's key is this one: before sign-in there is no key, and a
    // different user has a different file.
    private byte[]? _cacheKey;

    public PendingTranscriptionStore(CredentialManager credentials) : this(credentials, StorePath) { }

    // Test hook — lets tests point at a scratch file.
    internal PendingTranscriptionStore(CredentialManager credentials, string storePath)
    {
        _credentials = credentials;
        _storePath = storePath;
    }

    /// <summary>
    /// Failed attempts after which an entry stops being retried automatically and
    /// reads as a permanent failure (<see cref="PermanentFailure.RetriesExhausted"/>).
    /// Matches macOS (<c>PendingAudioUploadCoordinator.Policy.maxAutoRetries</c>).
    /// Unlike the Mac, Upload Now does not retry it either: the main window offers
    /// Remove for these instead, so Upload Now only ever sends live entries.
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
                // A fresh ladder makes a capped entry live again; missing files stay missing.
                store[sessionId] = existing with
                {
                    RetryCount = 0,
                    PermanentFailure = existing.PermanentFailure == Services.PermanentFailure.RetriesExhausted
                        ? null
                        : existing.PermanentFailure,
                };
                Persist(store);
            }
        }
    }

    /// <summary>
    /// Record that an entry can never upload, and why. It stays in the store (so
    /// the launch orphan scan, which skips ids the store holds, cannot re-queue
    /// its folder) until the therapist removes it from the main window.
    /// No-op if the entry is gone.
    /// </summary>
    public void MarkPermanentlyFailed(string sessionId, PermanentFailure reason)
    {
        lock (_lock)
        {
            var store = Load();
            if (store.TryGetValue(sessionId, out var existing) && existing.PermanentFailure != reason)
            {
                store[sessionId] = existing with { PermanentFailure = reason };
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
            _cache = null;
            _cacheKey = null;
            if (File.Exists(_storePath))
                File.Delete(_storePath);
        }
    }

    /// <summary>
    /// True while a signed-in user's key is available, so a write reaches disk.
    /// False on launch until the saved session is restored, and after sign-out.
    /// Callers that adopt or enqueue should wait rather than write into the void.
    /// </summary>
    public bool CanPersist
    {
        get
        {
            lock (_lock)
            {
                return _credentials.GetOrCreateUserEncryptionKey() != null;
            }
        }
    }

    /// <summary>
    /// The queue for the current key. With no key (not signed in yet, or signed
    /// out) this is a throwaway empty dictionary that is never cached: the real
    /// queue is still on disk, and caching an empty stand-in here is how a later
    /// <see cref="Persist"/> used to overwrite it. The app's launch scan runs
    /// before session restore has set the active user, so that window is hit on
    /// every cold start.
    /// </summary>
    private Dictionary<string, PendingTranscription> Load()
    {
        var key = _credentials.GetOrCreateUserEncryptionKey();
        if (key == null) return [];

        if (_cache != null && _cacheKey != null && key.AsSpan().SequenceEqual(_cacheKey))
            return _cache;

        _cache = ReadFromDisk(key);
        _cacheKey = key;
        return _cache;
    }

    private Dictionary<string, PendingTranscription> ReadFromDisk(byte[] key)
    {
        if (!File.Exists(_storePath)) return [];

        try
        {
            var fileBytes = File.ReadAllBytes(_storePath);
            using var encryptor = new AesGcmEncryptor(key, "device-key");
            var decrypted = encryptor.Decrypt(fileBytes);
            var json = Encoding.UTF8.GetString(decrypted);
            return JsonSerializer.Deserialize<Dictionary<string, PendingTranscription>>(json, JsonOptions) ?? [];
        }
        catch (Exception ex)
        {
            // Unreadable under this key (corrupt, or written by another user of
            // this Windows account). Start empty, as before, but say so.
            App.Log($"PendingTranscriptionStore: could not read the queue ({ex.GetType().Name}); starting empty.");
            return [];
        }
    }

    private void Persist(Dictionary<string, PendingTranscription> store)
    {
        var key = _credentials.GetOrCreateUserEncryptionKey();
        // No key: the caller mutated a throwaway from Load(). Dropping the write
        // is the only safe outcome, since the file on disk belongs to a key we
        // do not have.
        if (key == null) return;

        var dir = Path.GetDirectoryName(_storePath);
        if (!string.IsNullOrEmpty(dir))
            Directory.CreateDirectory(dir);

        var json = JsonSerializer.Serialize(store, JsonOptions);
        var plaintext = Encoding.UTF8.GetBytes(json);
        using var encryptor = new AesGcmEncryptor(key, "device-key");
        var encrypted = encryptor.Encrypt(plaintext);
        File.WriteAllBytes(_storePath, encrypted);

        _cache = store;
        _cacheKey = key;
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
    int? SampleRate = null,
    // Why the entry can never upload, once the resume pass has found out. Optional
    // so older entries still decode; a legacy entry already at the retry cap reads
    // as RetriesExhausted through Failure below until the next pass stamps it.
    PermanentFailure? PermanentFailure = null)
{
    /// <summary>The moment the backoff ladder counts from.</summary>
    [JsonIgnore]
    public DateTime BackoffAnchor => LastAttemptAt ?? CreatedAt;

    /// <summary>
    /// Why the entry will not be uploaded: its mic sidecar is gone
    /// (<see cref="Services.PermanentFailure.FilesMissing"/>), or it has failed
    /// <see cref="PendingTranscriptionStore.MaxAutoRetries"/> times
    /// (<see cref="Services.PermanentFailure.RetriesExhausted"/>). Null for a live entry.
    /// </summary>
    [JsonIgnore]
    public PermanentFailure? Failure => PermanentFailure
        ?? (RetryCount >= PendingTranscriptionStore.MaxAutoRetries
            ? Services.PermanentFailure.RetriesExhausted
            : null);

    /// <summary>
    /// The entry is dead: neither the scheduled pass nor Upload Now attempts it,
    /// it does not count toward the upload backlog, and the main window offers to
    /// remove it.
    /// </summary>
    [JsonIgnore]
    public bool IsPermanentlyFailed => Failure is not null;
}

/// <summary>Why a queued upload will never be attempted again.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<PermanentFailure>))]
public enum PermanentFailure
{
    /// <summary>The mic sidecar the entry points at no longer exists.</summary>
    FilesMissing,

    /// <summary>It failed <see cref="PendingTranscriptionStore.MaxAutoRetries"/> times.</summary>
    RetriesExhausted,
}
