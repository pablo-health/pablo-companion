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

/// <summary>
/// Where a queued entry sits in the upload → note lifecycle. Mirrors the Swift
/// <c>PendingAudioUpload.State</c> in <c>CompanionSessionCore</c>.
///
/// A successful upload does NOT delete the audio: acceptance is not completion,
/// and the backend can still fail to produce a note. The entry moves to
/// <see cref="AwaitingNote"/> and the audio is kept until a status check
/// confirms the note exists (delete) or the backend failed (re-queue).
/// </summary>
public enum UploadLifecycleState
{
    /// The audio still needs to be uploaded.
    PendingUpload,

    /// The upload was accepted; waiting for the backend to produce the note
    /// before the local audio can be deleted.
    AwaitingNote,
}
