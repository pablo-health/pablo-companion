namespace PabloCompanion.Services;

/// <summary>
/// Orchestrates 1:1 session transcription: mic → Therapist, system → Client.
/// Port of core/src/session_pipeline.rs.
/// </summary>
public sealed class SessionTranscriptionPipeline
{
    /// <summary>
    /// Transcribe a 1:1 session from mic and optional system audio PCM sidecars.
    /// </summary>
    public async Task<TranscriptResult> TranscribeSessionAsync(
        string sessionId,
        string micPath,
        string? systemPath,
        string modelPath,
        bool swapSpeakers = false,
        IProgress<TranscriptionProgress>? progress = null,
        CancellationToken ct = default)
    {
        var micLabel = swapSpeakers ? SpeakerLabel.Client : SpeakerLabel.Therapist;
        var sysLabel = swapSpeakers ? SpeakerLabel.Therapist : SpeakerLabel.Client;

        // Preprocess mic audio
        progress?.Report(new TranscriptionProgress(
            TranscriptionState.Preprocessing, 0, "Preprocessing mic audio..."));

        var micAudio = await AudioPreprocessor.PreprocessMicPcmAsync(micPath);
        ct.ThrowIfCancellationRequested();

        // Transcribe mic
        progress?.Report(new TranscriptionProgress(
            TranscriptionState.Transcribing, 0.1, "Transcribing mic audio..."));

        var micRaw = await WhisperTranscriber.TranscribeAsync(modelPath, micAudio, ct);

        var segments = new List<TranscriptSegment>();
        foreach (var s in micRaw)
        {
            segments.Add(new TranscriptSegment(
                micLabel, s.StartMs / 1000.0, s.EndMs / 1000.0, s.Text));
        }

        // Process system audio if available
        if (!string.IsNullOrEmpty(systemPath) && File.Exists(systemPath))
        {
            progress?.Report(new TranscriptionProgress(
                TranscriptionState.Preprocessing, 0.5, "Preprocessing system audio..."));

            var sysAudio = await AudioPreprocessor.PreprocessSystemPcmAsync(systemPath);
            ct.ThrowIfCancellationRequested();

            progress?.Report(new TranscriptionProgress(
                TranscriptionState.Transcribing, 0.6, "Transcribing system audio..."));

            var sysRaw = await WhisperTranscriber.TranscribeAsync(modelPath, sysAudio, ct);

            foreach (var s in sysRaw)
            {
                segments.Add(new TranscriptSegment(
                    sysLabel, s.StartMs / 1000.0, s.EndMs / 1000.0, s.Text));
            }
        }

        // Merge: sort by start time
        segments.Sort((a, b) => a.StartSeconds.CompareTo(b.StartSeconds));

        progress?.Report(new TranscriptionProgress(
            TranscriptionState.Transcribing, 1.0, "Transcription complete"));

        return new TranscriptResult(sessionId, [.. segments]);
    }
}
