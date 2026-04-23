using AudioCapture.Models;
using PabloCompanion.Models;
using PabloCompanion.Services;
using Xunit;

namespace PabloCompanion.Tests.Services;

[Collection("SessionRecordingStore")]
public class SessionRecordingStoreTests : IDisposable
{
    private readonly string _tempDir;
    private readonly SessionRecordingStore _store;

    public SessionRecordingStoreTests()
    {
        // Override the store path by creating a temp directory
        _tempDir = Path.Combine(Path.GetTempPath(), $"pablo_test_{Guid.NewGuid():N}");
        Directory.CreateDirectory(_tempDir);
        _store = new SessionRecordingStore();
    }

    public void Dispose()
    {
        _store.Clear();
        if (Directory.Exists(_tempDir))
            Directory.Delete(_tempDir, recursive: true);
    }

    private static LocalRecording MakeRecording(string filePath = "test.wav") => new(
        Id: Guid.NewGuid(),
        FilePath: filePath,
        Duration: 120.5,
        CreatedAt: DateTime.UtcNow,
        IsEncrypted: true,
        Checksum: "abc123",
        ChannelLayout: ChannelLayout.SeparatedStereo,
        MicPcmFilePath: null,
        SystemPcmFilePath: null,
        IsUploaded: false);

    [Fact]
    public void SaveAndGet_RoundTrip()
    {
        var recording = MakeRecording("session1.wav");
        _store.Save("session-1", recording);

        var retrieved = _store.Get("session-1");
        Assert.NotNull(retrieved);
        Assert.Equal("session1.wav", retrieved.FilePath);
        Assert.Equal(120.5, retrieved.Duration);
        Assert.True(retrieved.IsEncrypted);
    }

    [Fact]
    public void Get_MissingSession_ReturnsNull()
    {
        Assert.Null(_store.Get("nonexistent"));
    }

    [Fact]
    public void GetAll_ReturnsAllSessions()
    {
        _store.Save("s1", MakeRecording("a.wav"));
        _store.Save("s2", MakeRecording("b.wav"));

        var all = _store.GetAll();
        Assert.Equal(2, all.Count);
        Assert.True(all.ContainsKey("s1"));
        Assert.True(all.ContainsKey("s2"));
    }

    [Fact]
    public void Remove_DeletesSession()
    {
        _store.Save("s1", MakeRecording());
        _store.Remove("s1");

        Assert.Null(_store.Get("s1"));
    }

    [Fact]
    public void Clear_RemovesEverything()
    {
        _store.Save("s1", MakeRecording());
        _store.Save("s2", MakeRecording());
        _store.Clear();

        Assert.Empty(_store.GetAll());
    }

    [Fact]
    public void Save_OverwritesExisting()
    {
        _store.Save("s1", MakeRecording("old.wav"));
        _store.Save("s1", MakeRecording("new.wav"));

        var retrieved = _store.Get("s1");
        Assert.Equal("new.wav", retrieved!.FilePath);
    }
}
