using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using PabloCompanion.Services;

namespace PabloCompanion.ViewModels;

/// <summary>
/// Manages transcription state, model downloads, and transcript display.
/// </summary>
public partial class TranscriptionViewModel : ObservableObject
{
    private readonly SessionTranscriptionPipeline _pipeline;
    private readonly WhisperModelManager _modelManager;
    private readonly TranscriptStore _store;
    private readonly SessionRecordingStore _recordingStore;
    private CancellationTokenSource? _cts;

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
        SessionRecordingStore recordingStore)
    {
        _pipeline = pipeline;
        _modelManager = modelManager;
        _store = store;
        _recordingStore = recordingStore;
    }

    public bool IsModelAvailable => _modelManager.IsModelAvailable(QualityPreset);

    [RelayCommand]
    public async Task TranscribeSessionAsync(string sessionId)
    {
        if (State != TranscriptionState.Idle && State != TranscriptionState.Complete &&
            State != TranscriptionState.Error)
            return;

        // Check for existing transcript
        var existing = _store.Get(sessionId);
        if (existing != null)
        {
            TranscriptText = existing;
            State = TranscriptionState.Complete;
            ActiveSessionId = sessionId;
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

            // Persist and display
            _store.Save(sessionId, rendered);
            TranscriptText = rendered;
            State = TranscriptionState.Complete;
            Progress = 1.0;
            ProgressMessage = "Transcription complete";
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

    /// <summary>
    /// Get an existing transcript for a session from the local store.
    /// </summary>
    public string? GetTranscript(string sessionId) => _store.Get(sessionId);

    public string GetModelSizeLabel() => _modelManager.GetModelSizeLabel(QualityPreset);

    /// <summary>
    /// Clears all transcript data. Called on sign-out to prevent PHI leakage.
    /// </summary>
    public void ClearAllData()
    {
        CancelTranscription();
        _store.Clear();
        State = TranscriptionState.Idle;
        Progress = 0;
        ProgressMessage = null;
        ErrorMessage = null;
        TranscriptText = null;
        ActiveSessionId = null;
    }
}
