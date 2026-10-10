using PabloCompanion.Models;

namespace PabloCompanion.ViewModels;

/// <summary>
/// The part of recording the session start and the AI-notes consent flow drive:
/// arm capture for a session and know whether it is running, and stop it. A seam
/// so the start and decline flows are testable without a microphone; the app
/// uses <see cref="RecordingViewModelRecorder"/>.
/// </summary>
public interface ISessionRecorder
{
    /// <summary>The session capture is running for, if any.</summary>
    string? ActiveSessionId { get; }

    /// <summary>Arms capture for the session. True once it is recording.</summary>
    Task<bool> StartForSessionAsync(string sessionId);

    /// <summary>Stops capture, filing the last segment under the active session.</summary>
    Task StopAsync();
}

/// <summary>The app's recorder: <see cref="RecordingViewModel"/>.</summary>
public sealed class RecordingViewModelRecorder(RecordingViewModel recordingVm) : ISessionRecorder
{
    public string? ActiveSessionId => recordingVm.ActiveSessionId;

    public async Task<bool> StartForSessionAsync(string sessionId)
    {
        // StartRecordingAsync reports a capture failure by returning to Idle with
        // no active session rather than by throwing.
        await recordingVm.StartRecordingAsync(sessionId);
        return recordingVm.ActiveSessionId == sessionId && recordingVm.State != RecordingUIState.Idle;
    }

    public Task StopAsync() => recordingVm.StopRecordingAsync();
}
