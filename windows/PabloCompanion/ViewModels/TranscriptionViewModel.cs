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
///   2. On a 2xx the backend owns the audio, so the local recording is deleted
///      (<see cref="RecordingCleaner"/>) — it is PHI, and it is large.
///   3. On failure the session stays in <see cref="PendingTranscriptionStore"/>
///      so it can be retried, and its audio stays on disk.
///   4. <see cref="ResumePendingUploadsAsync"/> runs on app launch with
///      exponential backoff; survives sign-out / sign-in because the pending
///      entries are AES-GCM encrypted with the device key and carry the audio
///      paths inline.
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
        if (pending.Length == 0) return;

        App.Log($"ResumePendingUploads: {pending.Length} item(s) in queue");

        foreach (var item in pending)
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

    /// <summary>
    /// Manual "Retry now" — ignores backoff, tries every pending item once.
    /// </summary>
    public async Task ForceRetryPendingUploadsAsync()
    {
        foreach (var item in _pendingStore.GetAll())
        {
            await UploadFromPendingAsync(item);
        }
    }

    /// <summary>
    /// Current transcription state for a specific session, used by UI badges.
    /// </summary>
    public TranscriptionState GetSessionTranscriptionState(string sessionId)
    {
        return _pendingStore.Get(sessionId) != null
            ? TranscriptionState.PendingUpload
            : TranscriptionState.Complete;
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
            _pendingStore.Remove(item.SessionId);
            PendingUploadCount = _pendingStore.GetAll().Length;
            App.Log($"  upload OK session={item.SessionId} retry={item.RetryCount}");

            // Only now is the audio genuinely safe to destroy: this call returned
            // 2xx, which is the backend confirming it has the recording and has
            // queued it for transcription. Nothing earlier in the flow proves that.
            //
            // Caught here rather than falling through to the retry path below: a
            // delete failure must never turn a confirmed upload back into a retry.
            // The files simply stay, the next launch re-adopts them, and the
            // re-upload takes a bounded INVALID_STATUS rejection. The cleaner
            // already swallows its own errors — this guard is what keeps that from
            // being load-bearing.
            try
            {
                _cleaner.DeleteSession(item.SessionId);
            }
            catch (Exception ex)
            {
                App.LogException("TranscriptionViewModel.DeleteAfterUpload", ex);
            }

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
