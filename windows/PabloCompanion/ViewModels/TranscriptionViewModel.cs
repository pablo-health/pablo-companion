using AudioCapture.Storage;
using CommunityToolkit.Mvvm.ComponentModel;
using PabloCompanion.Models;
using PabloCompanion.Services;

namespace PabloCompanion.ViewModels;

/// <summary>
/// Orchestrates cloud-based transcription: uploads encrypted audio sidecars
/// to the Pablo backend, which produces the transcript + SOAP note server-
/// side. Mirrors <c>TranscriptionViewModel.swift</c> on macOS.
///
/// Flow:
///   1. <see cref="UploadAudioAsync"/> — decrypts PCM sidecars (if encrypted)
///      to temp files, POSTs them to <c>/api/sessions/{id}/upload-audio</c>.
///   2. On a 2xx the entry moves to <see cref="UploadLifecycleState.AwaitingNote"/>
///      and the audio is KEPT. Acceptance is not completion: transcription can
///      still fail, and deleting on the ack once turned a transient backend race
///      into permanent loss (audio gone, no note).
///   3. On failure the session stays PendingUpload in
///      <see cref="PendingTranscriptionStore"/> so it can be retried, and its
///      audio stays on disk.
///   4. <see cref="ResumePendingUploadsAsync"/> runs on app launch with
///      exponential backoff; survives sign-out / sign-in because the pending
///      entries are AES-GCM encrypted with the device key and carry the audio
///      paths inline. On the same cadence it calls
///      <see cref="ReconcileAwaitingNotesAsync"/>, which polls the backend and
///      deletes the local audio only once the note exists (or re-queues the
///      upload if the backend failed) — never on an inconclusive check.
/// </summary>
public partial class TranscriptionViewModel : ObservableObject
{
    private readonly SessionRecordingStore _recordingStore;
    private readonly PendingTranscriptionStore _pendingStore;
    private readonly APIClient _apiClient;
    private readonly CredentialManager _credentials;
    private readonly RecordingCleaner _cleaner;

    // Exponential backoff — matches macOS (PendingTranscriptStore behavior).
    private const int BaseBackoffSeconds = 300;    // 5 minutes
    private const int MaxBackoffSeconds = 14400;   // 4 hours
    private const int MaxAutoRetries = 10;

    [ObservableProperty]
    public partial TranscriptionState State { get; set; } = TranscriptionState.Idle;

    [ObservableProperty]
    public partial double Progress { get; set; }

    [ObservableProperty]
    public partial string? ProgressMessage { get; set; }

    [ObservableProperty]
    public partial string? ErrorMessage { get; set; }

    [ObservableProperty]
    public partial string? ActiveSessionId { get; set; }

    [ObservableProperty]
    public partial int PendingUploadCount { get; set; }

    public TranscriptionViewModel(
        SessionRecordingStore recordingStore,
        PendingTranscriptionStore pendingStore,
        APIClient apiClient,
        CredentialManager credentials,
        RecordingCleaner cleaner)
    {
        _recordingStore = recordingStore;
        _pendingStore = pendingStore;
        _apiClient = apiClient;
        _credentials = credentials;
        _cleaner = cleaner;

        PendingUploadCount = _pendingStore.GetAll().Length;
    }

    /// <summary>
    /// Enqueue a session for cloud transcription and kick off an immediate
    /// upload attempt. Called by <c>SessionViewModel.EndSessionAsync</c>.
    /// </summary>
    public async Task UploadAudioAsync(string sessionId)
    {
        if (State == TranscriptionState.Uploading) return;

        var recording = _recordingStore.Get(sessionId);
        if (recording?.MicPcmFilePath == null)
        {
            ErrorMessage = "No recording found for this session.";
            State = TranscriptionState.Error;
            return;
        }

        // Persist paths so retries survive sign-out (which wipes the recording store).
        _pendingStore.Add(
            sessionId: sessionId,
            micPath: recording.MicPcmFilePath,
            systemPath: recording.SystemPcmFilePath,
            isEncrypted: recording.IsEncrypted);
        PendingUploadCount = _pendingStore.GetAll().Length;

        ActiveSessionId = sessionId;

        // Cheap read-only liveness probe before moving the audio. If the
        // server-side session has already idled out, the upload can only 401 —
        // surface the re-auth flow now (VerifySessionAliveAsync raises it) and
        // leave the entry queued. It drains via the retry loop after sign-in.
        if (!await _apiClient.VerifySessionAliveAsync())
        {
            State = TranscriptionState.PendingUpload;
            ProgressMessage = "Session expired — sign in to resume the upload";
            App.Log($"Skipping audio upload for session={sessionId}: server session is no longer active");
            return;
        }

        State = TranscriptionState.Uploading;
        Progress = 0.1;
        ProgressMessage = "Uploading audio to Pablo...";
        ErrorMessage = null;

        var uploaded = await UploadFromPendingAsync(new PendingTranscription(
            SessionId: sessionId,
            MicPath: recording.MicPcmFilePath,
            SystemPath: recording.SystemPcmFilePath,
            IsEncrypted: recording.IsEncrypted,
            CreatedAt: DateTime.UtcNow,
            RetryCount: 0));

        if (uploaded)
        {
            State = TranscriptionState.Complete;
            Progress = 1.0;
            ProgressMessage = "Upload complete";
        }
        else
        {
            State = TranscriptionState.PendingUpload;
            ProgressMessage = "Upload failed — will retry later";
        }
    }

    /// <summary>
    /// Retry queued uploads with exponential backoff. Invoked on app launch.
    /// </summary>
    public async Task ResumePendingUploadsAsync()
    {
        var pending = _pendingStore.GetAll();
        PendingUploadCount = pending.Length;

        // Only entries that still need uploading are drained here; AwaitingNote
        // entries are left for ReconcileAwaitingNotesAsync below.
        var uploads = pending.Where(p => p.State == UploadLifecycleState.PendingUpload).ToArray();
        if (uploads.Length > 0)
        {
            App.Log($"ResumePendingUploads: {uploads.Length} item(s) in queue");

            foreach (var item in uploads)
            {
                if (item.RetryCount >= MaxAutoRetries)
                {
                    App.Log($"  skip session={item.SessionId} retry={item.RetryCount} (max retries exhausted)");
                    continue;
                }
                if (item.RetryCount > 0)
                {
                    var backoffSeconds = Math.Min(
                        BaseBackoffSeconds * Math.Pow(2, item.RetryCount - 1),
                        MaxBackoffSeconds);
                    if ((DateTime.UtcNow - item.CreatedAt).TotalSeconds < backoffSeconds)
                    {
                        App.Log($"  skip session={item.SessionId} retry={item.RetryCount} (backoff)");
                        continue;
                    }
                }

                await UploadFromPendingAsync(item);
            }
        }

        // Same cadence: check whether any already-uploaded session now has its
        // note, so the audio can finally be deleted (or re-queued on failure).
        var confirmed = await ReconcileAwaitingNotesAsync();
        if (confirmed > 0)
            App.Log($"Reconcile: confirmed {confirmed} note(s); deleted local audio");
    }

    /// <summary>
    /// Check every AwaitingNote entry against the backend and act on the answer:
    /// delete the audio once the note exists, re-queue the upload if the backend
    /// failed, or leave it be while transcription is still running.
    ///
    /// Runs on the same launch/timer cadence as the upload drain, so a therapist
    /// who closed the app mid-transcription still gets the audio cleaned up (or
    /// recovered) on the next launch. Mirrors the Swift
    /// <c>PendingAudioUploadCoordinator.reconcile()</c>.
    /// </summary>
    /// <returns>The number of sessions whose note was confirmed and audio deleted.</returns>
    public async Task<int> ReconcileAwaitingNotesAsync()
    {
        var awaiting = _pendingStore.GetAll()
            .Where(e => e.State == UploadLifecycleState.AwaitingNote)
            .ToArray();
        if (awaiting.Length == 0) return 0;

        var confirmed = 0;
        foreach (var entry in awaiting)
        {
            SessionNoteOutcome outcome;
            try
            {
                outcome = await CheckNoteOutcomeAsync(entry.SessionId);
            }
            catch (Exception ex)
            {
                // Inconclusive — a network blip is not "no note". Never delete on
                // a failed check; keep the audio and try again next cycle.
                App.Log($"  note-status check failed session={entry.SessionId}; keeping audio ({ex.GetType().Name})");
                continue;
            }

            switch (outcome)
            {
                case SessionNoteOutcome.NoteReady:
                    _pendingStore.Remove(entry.SessionId);
                    // A delete failure must never un-confirm a note that exists:
                    // the audio is safely on the backend and the leftover files
                    // are a disk-space problem, not a data-loss one.
                    try
                    {
                        _cleaner.DeleteSession(entry.SessionId);
                    }
                    catch (Exception ex)
                    {
                        App.LogException("TranscriptionViewModel.DeleteAfterNote", ex);
                    }
                    confirmed++;
                    break;

                case SessionNoteOutcome.Failed:
                    // Back to the upload queue with a fresh backoff ladder — the
                    // upload had succeeded, so this is a new attempt, not a
                    // continued failure.
                    _pendingStore.SetState(entry.SessionId, UploadLifecycleState.PendingUpload);
                    _pendingStore.ResetRetry(entry.SessionId);
                    App.Log($"  session={entry.SessionId} failed transcription; re-queued for upload");
                    break;

                case SessionNoteOutcome.StillWorking:
                    break;
            }
        }

        PendingUploadCount = _pendingStore.GetAll().Length;
        return confirmed;
    }

    /// <summary>
    /// Where the backend says an awaiting-note session stands, mapped onto the
    /// three actions reconcile can take. Keeps the status → action mapping in one
    /// place. Mirrors the Swift <c>checkOutcome</c> closure in
    /// <c>TranscriptionViewModel.swift</c>.
    /// </summary>
    private async Task<SessionNoteOutcome> CheckNoteOutcomeAsync(string sessionId)
    {
        var session = await _apiClient.FetchSessionAsync(sessionId);
        return session.Status switch
        {
            SessionStatus.PendingReview or SessionStatus.Finalized => SessionNoteOutcome.NoteReady,
            SessionStatus.Failed => SessionNoteOutcome.Failed,
            // transcribing / queued / processing / anything mid-flight
            _ => SessionNoteOutcome.StillWorking,
        };
    }

    /// <summary>The backend's verdict on an awaiting-note session.</summary>
    private enum SessionNoteOutcome
    {
        /// The note exists (pending_review / finalized) — safe to delete the audio.
        NoteReady,

        /// Transcription failed — keep the audio and re-queue the upload.
        Failed,

        /// Still transcribing — leave the entry alone and check again later.
        StillWorking,
    }

    /// <summary>
    /// Manual "Retry now" — ignores backoff, tries every pending item once.
    /// </summary>
    public async Task ForceRetryPendingUploadsAsync()
    {
        // Only entries still awaiting upload — an AwaitingNote entry has already
        // uploaded and must not be sent again; reconcile handles those.
        var uploads = _pendingStore.GetAll()
            .Where(p => p.State == UploadLifecycleState.PendingUpload)
            .ToArray();
        foreach (var item in uploads)
        {
            await UploadFromPendingAsync(item);
        }
    }

    /// <summary>
    /// Current transcription state for a specific session, used by UI badges.
    /// </summary>
    public TranscriptionState GetSessionTranscriptionState(string sessionId)
    {
        var entry = _pendingStore.Get(sessionId);
        if (entry == null) return TranscriptionState.Complete;
        // An AwaitingNote entry has already uploaded — the audio is only being
        // kept until the note lands — so the badge reads Complete, not "pending".
        return entry.State == UploadLifecycleState.AwaitingNote
            ? TranscriptionState.Complete
            : TranscriptionState.PendingUpload;
    }

    /// <summary>Signed-out cleanup. PendingTranscriptions stay intact so
    /// uploads can resume on sign-in; they are already encrypted at rest.
    /// </summary>
    public void ClearAllData()
    {
        State = TranscriptionState.Idle;
        Progress = 0;
        ProgressMessage = null;
        ErrorMessage = null;
        ActiveSessionId = null;
    }

    // --- internal ---

    private async Task<bool> UploadFromPendingAsync(PendingTranscription item)
    {
        try
        {
            AesGcmEncryptor? encryptor = null;
            if (item.IsEncrypted)
            {
                var keyBytes = _credentials.GetOrCreateUserEncryptionKey();
                if (keyBytes != null)
                    encryptor = new AesGcmEncryptor(keyBytes, "device-key");
            }

            // Decryption runs inside the try on purpose: a missing key throws, and that
            // has to land on the retry path below rather than escape. Neither caller of
            // this method wraps it, so an escaping throw would abort the whole resume
            // pass and strand every remaining item behind this one.
            using var mic = await PcmDecryptor.PrepareForUploadAsync(item.MicPath, encryptor);
            using DecryptedPcm? sys = item.SystemPath != null && File.Exists(item.SystemPath)
                ? await PcmDecryptor.PrepareForUploadAsync(item.SystemPath, encryptor)
                : null;

            // Self-healing upload: a session whose status PATCH never landed is
            // still "recording" server-side and rejects its audio with 400
            // INVALID_STATUS. The core client PATCHes it to recording_complete and
            // retries once; anything else lands here and takes the retry/backoff path.
            await _apiClient.UploadAudioWithSelfHealAsync(item.SessionId, mic.Path, sys?.Path);

            // A 2xx means the backend has the audio and has queued it — but
            // acceptance is not completion. Transcription can still fail to
            // produce a note, and deleting the audio on the ack once turned a
            // transient backend race into permanent loss: audio gone, no note.
            //
            // So keep the audio and move the entry to AwaitingNote.
            // ReconcileAwaitingNotesAsync polls the backend on the same launch/
            // timer cadence and deletes the audio only once the note exists
            // (or re-queues the upload if the backend failed).
            _pendingStore.SetState(item.SessionId, UploadLifecycleState.AwaitingNote);
            PendingUploadCount = _pendingStore.GetAll().Length;
            App.Log($"  upload OK session={item.SessionId} retry={item.RetryCount} -> awaiting note");

            return true;
        }
        catch (Exception ex)
        {
            _pendingStore.IncrementRetry(item.SessionId);
            ErrorMessage = $"Audio upload failed: {ex.Message}";
            App.Log($"  upload FAIL session={item.SessionId} retry={item.RetryCount}->{item.RetryCount + 1} type={ex.GetType().Name}{FormatStatusCode(ex.Message)}");
            return false;
        }
    }

    /// <summary>
    /// Extracts only the HTTP status digits from the upload exception (e.g. "(401)").
    /// Discards the rest of the message — the response body can contain PHI/PII.
    /// </summary>
    private static string FormatStatusCode(string? message)
    {
        if (string.IsNullOrEmpty(message)) return "";
        var match = System.Text.RegularExpressions.Regex.Match(message, @"\((\d{3})\)");
        return match.Success ? $" status={match.Groups[1].Value}" : "";
    }
}
