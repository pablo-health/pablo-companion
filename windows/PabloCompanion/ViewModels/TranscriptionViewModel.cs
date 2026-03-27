using System.Text.Json;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using PabloCompanion.Services;

namespace PabloCompanion.ViewModels;

/// <summary>
/// Manages transcription state, model downloads, transcript display,
/// upload to backend, pending store for resiliency, and settings persistence.
/// </summary>
public partial class TranscriptionViewModel : ObservableObject
{
    private readonly SessionTranscriptionPipeline _pipeline;
    private readonly WhisperModelManager _modelManager;
    private readonly TranscriptStore _store;
    private readonly SessionRecordingStore _recordingStore;
    private readonly PendingTranscriptionStore _pendingStore;
    private readonly APIClient _apiClient;
    private CancellationTokenSource? _cts;

    private static readonly string SettingsPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "PabloCompanion", "TranscriptionSettings.json");

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    // Exponential backoff constants (matching macOS)
    private const int BaseBackoffSeconds = 300;   // 5 minutes
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
    public partial string? TranscriptText { get; set; }

    [ObservableProperty]
    public partial string? ActiveSessionId { get; set; }

    [ObservableProperty]
    public partial QualityPreset QualityPreset { get; set; } = QualityPreset.Fast;

    [ObservableProperty]
    public partial bool AutoTranscribe { get; set; }

    public TranscriptionViewModel(
        SessionTranscriptionPipeline pipeline,
        WhisperModelManager modelManager,
        TranscriptStore store,
        SessionRecordingStore recordingStore,
        PendingTranscriptionStore pendingStore,
        APIClient apiClient)
    {
        _pipeline = pipeline;
        _modelManager = modelManager;
        _store = store;
        _recordingStore = recordingStore;
        _pendingStore = pendingStore;
        _apiClient = apiClient;

        LoadSettings();
    }

    public bool IsModelAvailable => _modelManager.IsModelAvailable(QualityPreset);

    partial void OnAutoTranscribeChanged(bool value) => SaveSettings();
    partial void OnQualityPresetChanged(QualityPreset value)
    {
        SaveSettings();
        OnPropertyChanged(nameof(IsModelAvailable));
    }

    [RelayCommand]
    public async Task TranscribeSessionAsync(string sessionId)
    {
        if (State != TranscriptionState.Idle && State != TranscriptionState.Complete &&
            State != TranscriptionState.PendingUpload && State != TranscriptionState.Error)
            return;

        // Check for existing transcript
        var existing = _store.Get(sessionId);
        if (existing != null)
        {
            TranscriptText = existing;
            State = TranscriptionState.Complete;
            ActiveSessionId = sessionId;

            // Try uploading if pending
            var pending = _pendingStore.Get(sessionId);
            if (pending?.TranscriptText != null)
                await TryUploadTranscriptAsync(sessionId, existing);
            return;
        }

        // Get recording paths
        var recording = _recordingStore.Get(sessionId);
        if (recording?.MicPcmFilePath == null)
        {
            ErrorMessage = "No recording found for this session.";
            State = TranscriptionState.Error;
            return;
        }

        _cts = new CancellationTokenSource();
        ActiveSessionId = sessionId;
        ErrorMessage = null;
        TranscriptText = null;

        var progressHandler = new Progress<TranscriptionProgress>(p =>
        {
            State = p.Phase;
            Progress = p.Progress;
            ProgressMessage = p.Message;
        });

        try
        {
            // Ensure model is downloaded
            var modelPath = await _modelManager.EnsureModelAsync(QualityPreset, progressHandler, _cts.Token);

            // Run transcription
            var result = await _pipeline.TranscribeSessionAsync(
                sessionId,
                recording.MicPcmFilePath,
                recording.SystemPcmFilePath,
                modelPath,
                swapSpeakers: false,
                progressHandler,
                _cts.Token);

            // Render to Google Meet format
            var opts = new GoogleMeetOptions(
                SessionDate: DateTime.Now.ToString("MMMM d, yyyy"),
                TherapistName: "Therapist",
                ClientName: "Client");

            var rendered = GoogleMeetRenderer.Render(result, opts);

            // Persist locally
            _store.Save(sessionId, rendered);
            _pendingStore.UpdateWithTranscript(sessionId, rendered);
            TranscriptText = rendered;
            Progress = 1.0;
            ProgressMessage = "Transcription complete";

            // Upload to backend
            await TryUploadTranscriptAsync(sessionId, rendered);
        }
        catch (OperationCanceledException)
        {
            State = TranscriptionState.Idle;
            ProgressMessage = "Transcription cancelled";
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.Message;
            State = TranscriptionState.Error;
        }
    }

    /// <summary>
    /// Attempt to upload transcript to backend. Sets state to PendingUpload on failure.
    /// </summary>
    private async Task TryUploadTranscriptAsync(string sessionId, string text)
    {
        try
        {
            await _apiClient.UploadTranscriptAsync(sessionId, "txt", text);
            _pendingStore.Remove(sessionId);
            State = TranscriptionState.Complete;
            ProgressMessage = "Transcript uploaded";
        }
        catch
        {
            _pendingStore.UpdateWithTranscript(sessionId, text);
            State = TranscriptionState.PendingUpload;
            ProgressMessage = "Upload failed — will retry later";
        }
    }

    /// <summary>
    /// Resume pending transcriptions and uploads on app launch.
    /// Items with transcript text: retry upload with exponential backoff.
    /// Items without transcript text: re-transcribe then upload.
    /// </summary>
    public async Task ResumePendingTranscriptionsAsync()
    {
        var pending = _pendingStore.GetAll();
        if (pending.Length == 0) return;

        foreach (var item in pending)
        {
            if (item.RetryCount >= MaxAutoRetries)
                continue;

            // Exponential backoff check
            var backoffSeconds = Math.Min(BaseBackoffSeconds * Math.Pow(2, item.RetryCount), MaxBackoffSeconds);
            var nextRetry = item.CreatedAt.AddSeconds(backoffSeconds * (item.RetryCount + 1));
            if (DateTime.UtcNow < nextRetry && item.RetryCount > 0)
                continue;

            if (item.TranscriptText != null)
            {
                // Already transcribed — just retry upload
                _pendingStore.IncrementRetry(item.SessionId);
                try
                {
                    await _apiClient.UploadTranscriptAsync(item.SessionId, "txt", item.TranscriptText);
                    _pendingStore.Remove(item.SessionId);
                }
                catch
                {
                    // Will retry on next launch or manual retry
                }
            }
            else
            {
                // Need to re-transcribe
                await TranscribeSessionAsync(item.SessionId);
            }
        }
    }

    /// <summary>
    /// Manual retry — ignores backoff, retries all pending uploads immediately.
    /// </summary>
    public async Task ForceRetryPendingUploadsAsync()
    {
        var pending = _pendingStore.GetAll();
        foreach (var item in pending)
        {
            if (item.TranscriptText != null)
            {
                try
                {
                    await _apiClient.UploadTranscriptAsync(item.SessionId, "txt", item.TranscriptText);
                    _pendingStore.Remove(item.SessionId);
                }
                catch
                {
                    _pendingStore.IncrementRetry(item.SessionId);
                }
            }
        }
    }

    /// <summary>
    /// Get transcription state for a specific session (for UI badges).
    /// </summary>
    public TranscriptionState GetSessionTranscriptionState(string sessionId)
    {
        if (_store.Get(sessionId) != null)
        {
            var pending = _pendingStore.Get(sessionId);
            return pending != null ? TranscriptionState.PendingUpload : TranscriptionState.Complete;
        }
        return TranscriptionState.Idle;
    }

    [RelayCommand]
    public void CancelTranscription()
    {
        _cts?.Cancel();
        _cts = null;
    }

    [RelayCommand]
    public async Task DownloadModelAsync()
    {
        if (State == TranscriptionState.DownloadingModel) return;

        _cts = new CancellationTokenSource();
        ErrorMessage = null;

        var progressHandler = new Progress<TranscriptionProgress>(p =>
        {
            State = p.Phase;
            Progress = p.Progress;
            ProgressMessage = p.Message;
        });

        try
        {
            await _modelManager.EnsureModelAsync(QualityPreset, progressHandler, _cts.Token);
            State = TranscriptionState.Idle;
            OnPropertyChanged(nameof(IsModelAvailable));
        }
        catch (OperationCanceledException)
        {
            State = TranscriptionState.Idle;
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.Message;
            State = TranscriptionState.Error;
        }
    }

    [RelayCommand]
    public void DeleteModel()
    {
        _modelManager.DeleteModel(QualityPreset);
        OnPropertyChanged(nameof(IsModelAvailable));
    }

    public string? GetTranscript(string sessionId) => _store.Get(sessionId);

    public string GetModelSizeLabel() => _modelManager.GetModelSizeLabel(QualityPreset);

    /// <summary>
    /// Uploads therapist and client audio to the backend for server-side transcription.
    /// This is the default flow on Windows — audio is always sent to the cloud.
    /// </summary>
    public async Task UploadAudioAsync(string sessionId)
    {
        if (State == TranscriptionState.Uploading)
            return;

        var recording = _recordingStore.Get(sessionId);
        if (recording?.MicPcmFilePath == null)
        {
            ErrorMessage = "No recording found for this session.";
            State = TranscriptionState.Error;
            return;
        }

        ActiveSessionId = sessionId;
        State = TranscriptionState.Uploading;
        Progress = 0.1;
        ProgressMessage = "Uploading audio to Pablo...";
        ErrorMessage = null;

        try
        {
            var response = await _apiClient.UploadAudioAsync(
                sessionId,
                recording.MicPcmFilePath,
                recording.SystemPcmFilePath);

            State = TranscriptionState.Complete;
            Progress = 1.0;
            ProgressMessage = response.Message;
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Audio upload failed: {ex.Message}";
            State = TranscriptionState.Error;
        }
    }

    /// <summary>
    /// Clears all transcript data. Called on sign-out to prevent PHI leakage.
    /// </summary>
    public void ClearAllData()
    {
        CancelTranscription();
        _store.Clear();
        _pendingStore.Clear();
        State = TranscriptionState.Idle;
        Progress = 0;
        ProgressMessage = null;
        ErrorMessage = null;
        TranscriptText = null;
        ActiveSessionId = null;
    }

    // --- Settings persistence ---

    private void LoadSettings()
    {
        if (!File.Exists(SettingsPath)) return;

        try
        {
            var json = File.ReadAllText(SettingsPath);
            var settings = JsonSerializer.Deserialize<TranscriptionSettings>(json, JsonOptions);
            if (settings != null)
            {
                AutoTranscribe = settings.AutoTranscribe;
                QualityPreset = settings.QualityPreset;
            }
        }
        catch
        {
            // Corrupt settings — use defaults
        }
    }

    private void SaveSettings()
    {
        try
        {
            var dir = Path.GetDirectoryName(SettingsPath);
            if (!string.IsNullOrEmpty(dir))
                Directory.CreateDirectory(dir);

            var settings = new TranscriptionSettings(AutoTranscribe, QualityPreset);
            var json = JsonSerializer.Serialize(settings, JsonOptions);
            File.WriteAllText(SettingsPath, json);
        }
        catch
        {
            // Best effort — non-critical
        }
    }

    private sealed record TranscriptionSettings(bool AutoTranscribe, QualityPreset QualityPreset);
}
