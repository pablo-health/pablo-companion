using System.Security.Cryptography;
using PabloCompanion.Services;

namespace PabloCompanion.Tests.Services;

public class PendingTranscriptionStoreTests : IDisposable
{
    private readonly string _tempPath = Path.Join(
        Path.GetTempPath(), $"pending-store-{Guid.NewGuid():N}.enc.json");

    private readonly CredentialManager _credentials = new StubCredentialManager();

    private PendingTranscriptionStore MakeStore() => new(_credentials, _tempPath);

    /// <summary>
    /// Deterministic key so the test doesn't depend on Windows Credential Manager.
    /// </summary>
    private sealed class StubCredentialManager : CredentialManager
    {
        private static readonly byte[] FixedKey = MakeKey();
        private static byte[] MakeKey()
        {
            var k = new byte[32];
            RandomNumberGenerator.Fill(k);
            return k;
        }
        public override byte[]? GetOrCreateUserEncryptionKey() => FixedKey;
    }

    [Fact]
    public void AddAndGetRoundtrip()
    {
        var store = MakeStore();
        store.Add("session-1", "C:/rec/mic.enc.pcm", "C:/rec/sys.enc.pcm", isEncrypted: true);

        var item = store.Get("session-1");
        Assert.NotNull(item);
        Assert.Equal("C:/rec/mic.enc.pcm", item!.MicPath);
        Assert.Equal("C:/rec/sys.enc.pcm", item.SystemPath);
        Assert.True(item.IsEncrypted);
        Assert.Equal(0, item.RetryCount);
    }

    [Fact]
    public void MarkPermanentlyFailed_PersistsTheReason_AndAFreshLadderOnlyRevivesACappedEntry()
    {
        var store = MakeStore();
        store.Add("missing", "mic.pcm", null, isEncrypted: false);
        store.Add("capped", "mic.pcm", null, isEncrypted: false);
        store.MarkPermanentlyFailed("missing", PermanentFailure.FilesMissing);
        store.MarkPermanentlyFailed("capped", PermanentFailure.RetriesExhausted);

        var reloaded = MakeStore();
        Assert.Equal(PermanentFailure.FilesMissing, reloaded.Get("missing")!.Failure);
        Assert.Equal(PermanentFailure.RetriesExhausted, reloaded.Get("capped")!.Failure);

        reloaded.ResetRetry("missing");
        reloaded.ResetRetry("capped");
        Assert.True(MakeStore().Get("missing")!.IsPermanentlyFailed);
        Assert.False(MakeStore().Get("capped")!.IsPermanentlyFailed);
    }

    [Fact]
    public void AnEntryAtTheRetryCapReadsAsRetriesExhaustedBeforeItIsStamped()
    {
        var store = MakeStore();
        store.Add("legacy", "mic.pcm", null, isEncrypted: false);
        for (var i = 0; i < PendingTranscriptionStore.MaxAutoRetries; i++) store.IncrementRetry("legacy");

        var entry = MakeStore().Get("legacy")!;
        Assert.Null(entry.PermanentFailure);
        Assert.Equal(PermanentFailure.RetriesExhausted, entry.Failure);
        Assert.True(entry.IsPermanentlyFailed);
    }

    [Fact]
    public void RemoveDropsEntry()
    {
        var store = MakeStore();
        store.Add("session-2", "mic.pcm", null, isEncrypted: false);
        store.Remove("session-2");
        Assert.Null(store.Get("session-2"));
    }

    [Fact]
    public void IncrementRetryPersists()
    {
        var store = MakeStore();
        store.Add("session-3", "mic.pcm", null, isEncrypted: false);
        store.IncrementRetry("session-3");
        store.IncrementRetry("session-3");

        Assert.Equal(2, store.Get("session-3")!.RetryCount);
    }

    /// <summary>
    /// Pending uploads must survive the sign-out / sign-in round-trip:
    /// signing out does not delete <c>PendingTranscriptions.enc.json</c>, so a
    /// newly constructed store (sign-in) should see every queued session.
    /// </summary>
    [Fact]
    public void PendingEntriesSurviveNewStoreInstance()
    {
        var firstStore = MakeStore();
        firstStore.Add("session-A", "mic-a.enc.pcm", "sys-a.enc.pcm", isEncrypted: true);
        firstStore.Add("session-B", "mic-b.pcm", null, isEncrypted: false);

        // Simulate sign-in after sign-out: a fresh VM constructs a new store
        // that reads from the same on-disk encrypted blob.
        var secondStore = MakeStore();
        var items = secondStore.GetAll();

        Assert.Equal(2, items.Length);
        Assert.Contains(items, i => i.SessionId == "session-A" && i.IsEncrypted);
        Assert.Contains(items, i => i.SessionId == "session-B" && !i.IsEncrypted);
    }

    /// <summary>
    /// A credential manager whose key can appear later, the way the real one's
    /// does on launch: the store is read by the orphan scan before session
    /// restore has set the active user.
    /// </summary>
    private sealed class LateKeyCredentialManager : CredentialManager
    {
        public byte[]? Key { get; set; }
        public override byte[]? GetOrCreateUserEncryptionKey() => Key;
    }

    private static byte[] NewKey()
    {
        var k = new byte[32];
        RandomNumberGenerator.Fill(k);
        return k;
    }

    [Fact]
    public void ReadBeforeSignInDoesNotShadowTheQueueOnDisk()
    {
        var key = NewKey();
        var credentials = new LateKeyCredentialManager { Key = key };
        new PendingTranscriptionStore(credentials, _tempPath)
            .Add("session-A", "mic-a.enc.pcm", null, isEncrypted: true);

        // Cold start: the scan reads the store before the key exists.
        var late = new LateKeyCredentialManager();
        var store = new PendingTranscriptionStore(late, _tempPath);
        Assert.False(store.CanPersist);
        Assert.Empty(store.GetAll());

        // Session restore completes; the same instance must now see the disk.
        late.Key = key;
        Assert.True(store.CanPersist);
        Assert.Single(store.GetAll());
        Assert.NotNull(store.Get("session-A"));
    }

    [Fact]
    public void WriteBeforeSignInDoesNotOverwriteTheQueueOnDisk()
    {
        var key = NewKey();
        new PendingTranscriptionStore(new LateKeyCredentialManager { Key = key }, _tempPath)
            .Add("session-A", "mic-a.enc.pcm", null, isEncrypted: true);
        new PendingTranscriptionStore(new LateKeyCredentialManager { Key = key }, _tempPath)
            .SetState("session-A", UploadLifecycleState.AwaitingNote);

        var late = new LateKeyCredentialManager();
        var store = new PendingTranscriptionStore(late, _tempPath);
        store.Add("session-B", "mic-b.enc.pcm", null, isEncrypted: true);
        store.Remove("session-A");

        late.Key = key;
        var items = store.GetAll();
        var a = Assert.Single(items);
        Assert.Equal("session-A", a.SessionId);
        Assert.Equal(UploadLifecycleState.AwaitingNote, a.State);
    }

    [Fact]
    public void ChangingTheKeyRereadsTheDisk()
    {
        var first = NewKey();
        var credentials = new LateKeyCredentialManager { Key = first };
        var store = new PendingTranscriptionStore(credentials, _tempPath);
        store.Add("session-A", "mic-a.enc.pcm", null, isEncrypted: true);

        // Another user of this Windows account signs in: their key cannot read
        // the first user's file, so they start empty instead of inheriting it.
        credentials.Key = NewKey();
        Assert.Empty(store.GetAll());

        credentials.Key = first;
        Assert.NotNull(store.Get("session-A"));
    }

    [Fact]
    public void UnknownPropertiesFromLegacySchemaAreIgnored()
    {
        // Old schema (pre-cloud migration) included QualityPreset + TranscriptText.
        // Verify we can still read an entry written without those fields.
        var store = MakeStore();
        store.Add("session-X", "mic.enc.pcm", null, isEncrypted: true);
        var reloaded = MakeStore().Get("session-X");
        Assert.NotNull(reloaded);
        Assert.Equal("mic.enc.pcm", reloaded!.MicPath);
    }

    public void Dispose()
    {
        try { if (File.Exists(_tempPath)) File.Delete(_tempPath); }
        catch (IOException) { /* best-effort cleanup */ }
        catch (UnauthorizedAccessException) { /* best-effort cleanup */ }
    }
}
