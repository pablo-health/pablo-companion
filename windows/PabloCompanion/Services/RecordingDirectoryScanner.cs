namespace PabloCompanion.Services;

/// <summary>
/// Scans the recordings directory on disk for sessions whose audio is on the
/// device but is NOT in <see cref="PendingTranscriptionStore"/>. Such recordings
/// are "orphans" — typically left behind by a code path that recorded audio but
/// never enqueued it for upload (e.g. the historical autoTranscribe=false bug,
/// or a process crash between End-Session and the enqueue step).
///
/// On launch the scanner adopts these orphans into PendingTranscriptionStore so
/// the existing retry loop in <see cref="ViewModels.TranscriptionViewModel.ResumePendingUploadsAsync"/>
/// picks them up and uploads them on the next pass.
///
/// Mirrors <c>RecordingDirectoryScanner.swift</c> on macOS, with a Windows-
/// specific simplification: each subdirectory of <c>Recordings\</c> is named
/// after the session ID, so we don't need to parse UUIDs out of filenames.
/// </summary>
public sealed class RecordingDirectoryScanner
{
    private static readonly string RecordingsRoot = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "PabloCompanion", "Recordings");

    private readonly PendingTranscriptionStore _pendingStore;
    private readonly string _recordingsRoot;

    public RecordingDirectoryScanner(PendingTranscriptionStore pendingStore)
        : this(pendingStore, RecordingsRoot) { }

    // Test seam.
    internal RecordingDirectoryScanner(PendingTranscriptionStore pendingStore, string recordingsRoot)
    {
        _pendingStore = pendingStore;
        _recordingsRoot = recordingsRoot;
    }

    /// <summary>
    /// Adopt every orphan into the pending store. Returns the number of new
    /// entries added. Best-effort — never throws.
    /// </summary>
    public int AdoptOrphans()
    {
        try
        {
            if (!Directory.Exists(_recordingsRoot)) return 0;

            var existing = _pendingStore.GetAll()
                .Select(p => p.SessionId)
                .ToHashSet(StringComparer.OrdinalIgnoreCase);

            var adopted = 0;
            foreach (var sessionDir in Directory.EnumerateDirectories(_recordingsRoot))
            {
                var sessionId = Path.GetFileName(sessionDir);
                if (string.IsNullOrEmpty(sessionId)) continue;
                if (existing.Contains(sessionId)) continue;

                var (micPath, systemPath, isEncrypted) = FindAudioFiles(sessionDir);
                if (micPath == null) continue;

                _pendingStore.Add(
                    sessionId: sessionId,
                    micPath: micPath,
                    systemPath: systemPath,
                    isEncrypted: isEncrypted);
                adopted++;
            }
            return adopted;
        }
        catch (Exception ex)
        {
            App.LogException("RecordingDirectoryScanner.AdoptOrphans", ex);
            return 0;
        }
    }

    private static (string? mic, string? system, bool isEncrypted) FindAudioFiles(string sessionDir)
    {
        string? mic = null;
        string? system = null;
        var isEncrypted = false;

        foreach (var file in Directory.EnumerateFiles(sessionDir))
        {
            var name = Path.GetFileName(file);
            if (name.EndsWith("_mic.enc.pcm", StringComparison.OrdinalIgnoreCase))
            {
                mic = file; isEncrypted = true;
            }
            else if (name.EndsWith("_mic.pcm", StringComparison.OrdinalIgnoreCase))
            {
                mic ??= file; // prefer encrypted match if both exist
            }
            else if (name.EndsWith("_system.enc.pcm", StringComparison.OrdinalIgnoreCase))
            {
                system = file; isEncrypted = true;
            }
            else if (name.EndsWith("_system.pcm", StringComparison.OrdinalIgnoreCase))
            {
                system ??= file;
            }
        }

        // Skip empty/zero-byte mic files.
        if (mic != null && new FileInfo(mic).Length == 0) return (null, null, false);

        return (mic, system, isEncrypted);
    }
}
