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
    /// The client declined AI-assisted notes on the recording. Deletes every file
    /// the session captured and every record that could lead an upload back to
    /// it: the queued upload, and the session -> recording map entry. Nothing of
    /// the session is left for the upload queue or the launch-time sweep
    /// (<see cref="RecordingDirectoryScanner.AdoptOrphans"/>, which adopts from
    /// the directory) to send. Mirrors macOS <c>RecordingCleaner.discardDeclined</c>.
    ///
    /// The records go first, so a file still locked by another handle can at
    /// worst leave audio on disk with nothing pointing at it to upload. Returns
    /// true when no audio for the session is left on disk. Never throws.
    /// </summary>
    public virtual bool DiscardDeclined(
        string sessionId,
        SessionRecordingStore recordingStore,
        PendingTranscriptionStore pendingStore)
    {
        if (string.IsNullOrWhiteSpace(sessionId)) return false;

        var mapped = SafeGet(() => recordingStore.Get(sessionId));
        SafeRun(() => pendingStore.Remove(sessionId));
        SafeRun(() => recordingStore.Remove(sessionId));

        DeleteSession(sessionId);
        DeleteLeftoverFiles(sessionId);

        // Capture files live in the session directory; a mapped path elsewhere
        // (an older layout) is removed by name too.
        var allGone = !Directory.Exists(SessionDirectory(sessionId));
        if (mapped is not null)
        {
            foreach (var path in new[] { mapped.FilePath, mapped.MicPcmFilePath, mapped.SystemPcmFilePath })
            {
                if (string.IsNullOrEmpty(path)) continue;
                try
                {
                    if (File.Exists(path)) File.Delete(path);
                }
                catch (Exception ex)
                {
                    App.LogException("RecordingCleaner.DiscardDeclined", ex);
                }
                allGone &= !File.Exists(path);
            }
        }
        App.Log($"  discarded declined audio for session={sessionId} complete={allGone}");
        return allGone;
    }

    private string SessionDirectory(string sessionId) => Path.Combine(_recordingsRoot, sessionId);

    /// <summary>
    /// After a directory delete that did not complete, removes what it can file by
    /// file, mic sidecars first: a mic file is what the launch-time sweep adopts
    /// for upload, so it is the one that must not survive.
    /// </summary>
    private void DeleteLeftoverFiles(string sessionId)
    {
        try
        {
            var root = Path.GetFullPath(_recordingsRoot)
                .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            var dir = Path.GetFullPath(Path.Combine(root, sessionId));
            if (!dir.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) return;
            if (!Directory.Exists(dir)) return;

            var files = Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories)
                .OrderBy(f => Path.GetFileName(f).Contains("_mic", StringComparison.OrdinalIgnoreCase) ? 0 : 1);
            foreach (var file in files)
            {
                try { File.Delete(file); }
                catch (Exception ex) { App.LogException("RecordingCleaner.DiscardDeclined", ex); }
            }
            try { Directory.Delete(dir, recursive: true); }
            catch (Exception ex) { App.LogException("RecordingCleaner.DiscardDeclined", ex); }
        }
        catch (Exception ex)
        {
            App.LogException("RecordingCleaner.DiscardDeclined", ex);
        }
    }

    private static void SafeRun(Action action)
    {
        try { action(); }
        catch (Exception ex) { App.LogException("RecordingCleaner.DiscardDeclined", ex); }
    }

    private static T? SafeGet<T>(Func<T?> get) where T : class
    {
        try { return get(); }
        catch (Exception ex)
        {
            App.LogException("RecordingCleaner.DiscardDeclined", ex);
            return null;
        }
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
            // path, then checked for containment: this deletes a directory tree
            // recursively, so it must only ever be able to name one strictly
            // inside Recordings\.
            //
            // Containment is checked on the resolved path, not by sanitising the
            // ID. Path.GetFileName is not a guard here: it maps ".." to "..",
            // which resolves to the *parent* of the recordings root, and "id/" to
            // "", which resolves to the root itself — either would take out every
            // session on the machine.
            // Trailing separators are trimmed so the containment prefix below can't
            // become a doubled separator that silently refuses every delete.
            var root = Path.GetFullPath(_recordingsRoot)
                .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            var sessionDir = Path.GetFullPath(Path.Combine(root, sessionId));

            if (!sessionDir.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            {
                App.Log($"  refusing to delete audio outside the recordings root for session={sessionId}");
                return false;
            }

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
