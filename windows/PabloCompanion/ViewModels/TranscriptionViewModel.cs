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
///   2. On failure the session stays in <see cref="PendingTranscriptionStore"/>
///      so it can be retried.
///   3. <see cref="ResumePendingUploadsAsync"/> runs on app launch with
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
        CredentialManager credentials)
    {
        _recordingStore = recordingStore;
        _pendingStore = pendingStore;
        _apiClient = apiClient;
        _credentials = credentials;

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
        AesGcmEncryptor? encryptor = null;
        if (item.IsEncrypted)
        {
            var keyBytes = _credentials.GetOrCreateUserEncryptionKey();
            if (keyBytes != null)
                encryptor = new AesGcmEncryptor(keyBytes, "device-key");
        }

        using var mic = await PcmDecryptor.PrepareForUploadAsync(item.MicPath, encryptor);
        using DecryptedPcm? sys = item.SystemPath != null && File.Exists(item.SystemPath)
            ? await PcmDecryptor.PrepareForUploadAsync(item.SystemPath, encryptor)
            : null;

        try
        {
            await _apiClient.UploadAudioAsync(item.SessionId, mic.Path, sys?.Path);
            _pendingStore.Remove(item.SessionId);
            PendingUploadCount = _pendingStore.GetAll().Length;
            App.Log($"  upload OK session={item.SessionId} retry={item.RetryCount}");
            return true;
        }
        catch (PabloException ex) when (IsInvalidStatus(ex))
        {
            // Backend rejected because session is still in "recording" — usually a
            // session from a buggy build where EndSessionAsync uploaded before the
            // status PATCH. Heal it: PATCH to recording_complete, retry the upload
            // once. If either step fails, fall back to the normal retry/backoff path.
            App.Log($"  upload 400 INVALID_STATUS session={item.SessionId} — attempting self-heal");
            try
            {
                await _apiClient.UpdateSessionStatusAsync(item.SessionId, SessionStatus.RecordingComplete);
                await _apiClient.UploadAudioAsync(item.SessionId, mic.Path, sys?.Path);
                _pendingStore.Remove(item.SessionId);
                PendingUploadCount = _pendingStore.GetAll().Length;
                App.Log($"  upload OK session={item.SessionId} (self-healed)");
                return true;
            }
            catch (Exception innerEx)
            {
                _pendingStore.IncrementRetry(item.SessionId);
                ErrorMessage = $"Audio upload failed: {innerEx.Message}";
                App.Log($"  upload FAIL session={item.SessionId} retry={item.RetryCount}->{item.RetryCount + 1} self-heal-failed type={innerEx.GetType().Name}{FormatStatusCode(innerEx.Message)}");
                return false;
            }
        }
        catch (Exception ex)
        {
            _pendingStore.IncrementRetry(item.SessionId);
            ErrorMessage = $"Audio upload failed: {ex.Message}";
            App.Log($"  upload FAIL session={item.SessionId} retry={item.RetryCount}->{item.RetryCount + 1} type={ex.GetType().Name}{FormatStatusCode(ex.Message)}");
            return false;
        }
    }

    private static bool IsInvalidStatus(PabloException ex) =>
        ex.StatusCode == 400 && ex.ErrorCode == "INVALID_STATUS";

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
