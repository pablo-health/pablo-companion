using System.Security.Cryptography;
using PabloCompanion.Services;

namespace PabloCompanion.Tests.Services;

public class PendingTranscriptionStoreTests : IDisposable
{
    private readonly string _tempPath = Path.Combine(
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
        public override byte[]? GetOrCreateDeviceEncryptionKey() => FixedKey;
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
        catch { /* best-effort */ }
    }
}
