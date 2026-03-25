using PabloCompanion.Services;

namespace PabloCompanion.Tests.Services;

public class TranscriptStoreTests : IDisposable
{
    private readonly CredentialManager _credentials = new();
    private readonly TranscriptStore _store;
    private readonly string _testSessionId = $"test-{Guid.NewGuid()}";

    public TranscriptStoreTests()
    {
        _store = new TranscriptStore(_credentials);
    }

    [Fact]
    public void SaveAndGetRoundtrip()
    {
        _store.Save(_testSessionId, "Hello transcript");
        var result = _store.Get(_testSessionId);
        Assert.Equal("Hello transcript", result);
    }

    [Fact]
    public void GetNonexistentReturnsNull()
    {
        var result = _store.Get("nonexistent-session");
        Assert.Null(result);
    }

    [Fact]
    public void RemoveDeletesTranscript()
    {
        _store.Save(_testSessionId, "To be removed");
        _store.Remove(_testSessionId);
        var result = _store.Get(_testSessionId);
        Assert.Null(result);
    }

    public void Dispose()
    {
        _store.Remove(_testSessionId);
    }
}
