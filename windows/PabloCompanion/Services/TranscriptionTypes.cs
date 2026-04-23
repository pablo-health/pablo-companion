namespace PabloCompanion.Services;

/// <summary>
/// UI-facing state for a session's audio upload / cloud transcription.
/// Mirrors the Swift `TranscriptionState` enum on macOS (see
/// mac/PabloCompanion/ViewModels/TranscriptionViewModel.swift).
/// </summary>
public enum TranscriptionState
{
    Idle,
    Uploading,
    Complete,
    PendingUpload,
    Error,
}
