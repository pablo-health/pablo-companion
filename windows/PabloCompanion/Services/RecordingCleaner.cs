namespace PabloCompanion.Services;

/// <summary>
/// Deletes a session's local audio once the backend has confirmed it holds the
/// recording.
///
/// Local session audio is PHI sitting on a therapist's laptop, and each session
/// leaves a mixed WAV plus mic and system PCM sidecars behind — on the order of
/// a gigabyte for a 50-minute session. Nothing used to remove any of it, so it
/// accumulated for the life of the install.
///
/// Deleting on confirmed upload also removes the need to track "uploaded" state
/// anywhere: file presence *is* the state. That is what stops
/// <see cref="RecordingDirectoryScanner.AdoptOrphans"/> re-adopting every
/// already-uploaded session on each launch and re-POSTing its audio to earn a
/// 400 INVALID_STATUS.
///
/// A session's audio lives in <c>Recordings\{sessionId}\</c> (see
/// <see cref="RecordingService.StartAsync"/>), so the session ID alone locates
/// everything to remove.
/// </summary>
public class RecordingCleaner
{
    private static readonly string RecordingsRoot = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "PabloCompanion", "Recordings");

    private readonly string _recordingsRoot;

    public RecordingCleaner() : this(RecordingsRoot) { }

    // Test seam.
    internal RecordingCleaner(string recordingsRoot)
    {
        _recordingsRoot = recordingsRoot;
    }

    /// <summary>
    /// Deletes the whole recording directory for <paramref name="sessionId"/> —
    /// mic and system sidecars plus any mixed file. Returns true if a directory
    /// was removed.
    ///
    /// Best-effort by contract: never throws. A file still locked by another
    /// handle leaves the directory in place, the next launch re-adopts it, and
    /// the re-upload takes a bounded INVALID_STATUS rejection. That is a far
    /// better outcome than failing an upload that actually succeeded.
    /// </summary>
    public virtual bool DeleteSession(string sessionId)
    {
        if (string.IsNullOrWhiteSpace(sessionId)) return false;

        try
        {
            // Rebuilt from the root rather than taken from a caller-supplied audio
            // path: this deletes a directory tree, and it must only ever be able to
            // name one inside Recordings\.
            var sessionDir = Path.Combine(_recordingsRoot, Path.GetFileName(sessionId));
            if (!Directory.Exists(sessionDir)) return false;

            Directory.Delete(sessionDir, recursive: true);
            App.Log($"  deleted local audio for session={sessionId}");
            return true;
        }
        catch (Exception ex)
        {
            App.LogException("RecordingCleaner.DeleteSession", ex);
            return false;
        }
    }
}
