using System.Security.Cryptography;
using PabloCompanion.Services;

namespace PabloCompanion.Tests.Services;

public sealed class RecordingDirectoryScannerTests : IDisposable
{
    private readonly string _recordingsRoot = Path.Combine(
        Path.GetTempPath(), $"scanner-recordings-{Guid.NewGuid():N}");
    private readonly string _pendingPath = Path.Combine(
        Path.GetTempPath(), $"scanner-pending-{Guid.NewGuid():N}.enc.json");

    private readonly CredentialManager _credentials = new StubCredentialManager();

    private PendingTranscriptionStore MakePendingStore() => new(_credentials, _pendingPath);
    private RecordingDirectoryScanner MakeScanner(PendingTranscriptionStore store)
        => new(store, _recordingsRoot);

    private void SeedSessionDir(string sessionId, bool encrypted = true, bool emptyMic = false, bool includeSystem = true)
    {
        var dir = Path.Combine(_recordingsRoot, sessionId);
        Directory.CreateDirectory(dir);
        var ts = "20260505_224735";
        var micName = encrypted ? $"recording_{ts}_mic.enc.pcm" : $"recording_{ts}_mic.pcm";
        var sysName = encrypted ? $"recording_{ts}_system.enc.pcm" : $"recording_{ts}_system.pcm";
        File.WriteAllBytes(Path.Combine(dir, micName), emptyMic ? [] : [1, 2, 3, 4]);
        if (includeSystem)
            File.WriteAllBytes(Path.Combine(dir, sysName), [5, 6, 7, 8]);
    }

    [Fact]
    public void AdoptOrphans_NoRoot_ReturnsZero()
    {
        // _recordingsRoot is never created.
        var scanner = MakeScanner(MakePendingStore());
        Assert.Equal(0, scanner.AdoptOrphans());
    }

    [Fact]
    public void AdoptOrphans_AddsEncryptedSessionToPending()
    {
        SeedSessionDir("orphan-1");
        var store = MakePendingStore();
        var scanner = MakeScanner(store);

        var adopted = scanner.AdoptOrphans();

        Assert.Equal(1, adopted);
        var entry = MakePendingStore().Get("orphan-1");
        Assert.NotNull(entry);
        Assert.True(entry!.IsEncrypted);
        Assert.EndsWith("_mic.enc.pcm", entry.MicPath);
        Assert.NotNull(entry.SystemPath);
        Assert.EndsWith("_system.enc.pcm", entry.SystemPath);
    }

    [Fact]
    public void AdoptOrphans_SkipsSessionsAlreadyPending()
    {
        SeedSessionDir("orphan-2");
        // Pre-populate the pending store as if upload was already enqueued.
        MakePendingStore().Add("orphan-2", "stale-mic.pcm", null, isEncrypted: false);

        var scanner = MakeScanner(MakePendingStore());
        var adopted = scanner.AdoptOrphans();

        Assert.Equal(0, adopted);
        // Existing entry untouched (paths still the stale ones we wrote).
        var entry = MakePendingStore().Get("orphan-2");
        Assert.NotNull(entry);
        Assert.Equal("stale-mic.pcm", entry!.MicPath);
    }

    [Fact]
    public void AdoptOrphans_SkipsSessionsWithoutMicFile()
    {
        var sessionDir = Path.Combine(_recordingsRoot, "no-mic");
        Directory.CreateDirectory(sessionDir);
        File.WriteAllText(Path.Combine(sessionDir, "stray-marker.txt"), "junk");

        var scanner = MakeScanner(MakePendingStore());
        Assert.Equal(0, scanner.AdoptOrphans());
        Assert.Null(MakePendingStore().Get("no-mic"));
    }

    [Fact]
    public void AdoptOrphans_SkipsZeroByteMicFile()
    {
        SeedSessionDir("empty-mic", emptyMic: true, includeSystem: false);

        var scanner = MakeScanner(MakePendingStore());
        Assert.Equal(0, scanner.AdoptOrphans());
        Assert.Null(MakePendingStore().Get("empty-mic"));
    }

    [Fact]
    public void AdoptOrphans_HandlesMultipleSessions()
    {
        SeedSessionDir("a");
        SeedSessionDir("b", encrypted: false);
        SeedSessionDir("c");

        var scanner = MakeScanner(MakePendingStore());
        Assert.Equal(3, scanner.AdoptOrphans());

        var store = MakePendingStore();
        Assert.NotNull(store.Get("a"));
        Assert.NotNull(store.Get("b"));
        Assert.NotNull(store.Get("c"));
        Assert.False(store.Get("b")!.IsEncrypted);
    }

    public void Dispose()
    {
        try { if (Directory.Exists(_recordingsRoot)) Directory.Delete(_recordingsRoot, recursive: true); }
        catch { /* best-effort */ }
        try { if (File.Exists(_pendingPath)) File.Delete(_pendingPath); }
        catch { /* best-effort */ }
    }

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
}
