using PabloCompanion.Services;

namespace PabloCompanion.Tests.Services;

/// <summary>
/// Covers post-upload PHI cleanup: the whole session directory goes (mic and
/// system sidecars plus the mixed file), only ever inside the recordings root,
/// and nothing about a missing or unremovable directory throws — the caller has
/// already told the therapist their audio uploaded.
/// </summary>
public sealed class RecordingCleanerTests : IDisposable
{
    private readonly string _root = Path.Join(
        Path.GetTempPath(), $"cleaner-{Guid.NewGuid():N}");

    public RecordingCleanerTests()
    {
        Directory.CreateDirectory(_root);
    }

    private RecordingCleaner MakeCleaner() => new(_root);

    private string SeedSession(string sessionId)
    {
        var dir = Path.Join(_root, sessionId);
        Directory.CreateDirectory(dir);
        File.WriteAllBytes(Path.Join(dir, "rec_mic.pcm"), new byte[64]);
        File.WriteAllBytes(Path.Join(dir, "rec_system.pcm"), new byte[64]);
        File.WriteAllBytes(Path.Join(dir, "rec.wav"), new byte[64]);
        return dir;
    }

    [Fact]
    public void DeleteSession_RemovesEntireSessionDirectory()
    {
        var dir = SeedSession("session-1");

        var deleted = MakeCleaner().DeleteSession("session-1");

        Assert.True(deleted);
        Assert.False(Directory.Exists(dir));
    }

    [Fact]
    public void DeleteSession_LeavesOtherSessionsAlone()
    {
        SeedSession("session-1");
        var other = SeedSession("session-2");

        MakeCleaner().DeleteSession("session-1");

        Assert.True(Directory.Exists(other));
    }

    [Fact]
    public void DeleteSession_WhenDirectoryMissing_ReturnsFalseAndDoesNotThrow()
    {
        var deleted = MakeCleaner().DeleteSession("never-recorded");

        Assert.False(deleted);
        Assert.True(Directory.Exists(_root));
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    public void DeleteSession_WithBlankSessionId_ReturnsFalse(string sessionId)
    {
        var deleted = MakeCleaner().DeleteSession(sessionId);

        Assert.False(deleted);
        Assert.True(Directory.Exists(_root));
    }

    /// <summary>
    /// This deletes a directory tree recursively from an ID that ultimately comes
    /// off the wire, so nothing above the recordings root may be nameable.
    /// </summary>
    [Fact]
    public void DeleteSession_WithTraversalInSessionId_CannotEscapeRecordingsRoot()
    {
        var victim = Path.Join(_root, "..", $"victim-{Guid.NewGuid():N}");
        Directory.CreateDirectory(victim);
        try
        {
            var deleted = MakeCleaner().DeleteSession(Path.Join("..", Path.GetFileName(victim)));

            Assert.False(deleted);
            Assert.True(Directory.Exists(victim));
        }
        finally
        {
            try { Directory.Delete(victim, recursive: true); } catch (IOException) { }
        }
    }

    /// <summary>
    /// The two IDs that a GetFileName-style sanitiser would wave through with the
    /// worst possible result: ".." resolves to the parent of the recordings root,
    /// and a trailing separator resolves to the root itself. Either one would
    /// recursively delete every session on the machine.
    /// </summary>
    [Theory]
    [InlineData("..")]
    [InlineData(".")]
    [InlineData("session-1/")]
    [InlineData("session-1\\")]
    public void DeleteSession_WithIdResolvingToRootOrAbove_RefusesUnlessStrictlyInside(string sessionId)
    {
        SeedSession("session-1");
        var sibling = Path.Join(_root, "sibling");
        Directory.CreateDirectory(sibling);

        MakeCleaner().DeleteSession(sessionId);

        // Whatever it did, it must not have taken out the root or its neighbours.
        Assert.True(Directory.Exists(_root));
        Assert.True(Directory.Exists(sibling));
    }

    [Fact]
    public void DeleteSession_WithAbsolutePath_RefusesToDelete()
    {
        var outside = Path.Join(Path.GetTempPath(), $"outside-{Guid.NewGuid():N}");
        Directory.CreateDirectory(outside);
        try
        {
            var deleted = MakeCleaner().DeleteSession(outside);

            Assert.False(deleted);
            Assert.True(Directory.Exists(outside));
        }
        finally
        {
            try { Directory.Delete(outside, recursive: true); } catch (IOException) { }
        }
    }

    public void Dispose()
    {
        try { if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true); }
        catch (IOException) { /* best-effort cleanup */ }
        catch (UnauthorizedAccessException) { /* best-effort cleanup */ }
    }
}
