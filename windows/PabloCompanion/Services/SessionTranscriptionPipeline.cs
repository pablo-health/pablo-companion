using AudioCapture.Storage;

namespace PabloCompanion.Services;

/// <summary>
/// Orchestrates 1:1 session transcription: mic → Therapist, system → Client.
/// Port of core/src/session_pipeline.rs.
/// </summary>
public sealed class SessionTranscriptionPipeline
{
    private readonly CredentialManager _credentials;

    public SessionTranscriptionPipeline(CredentialManager credentials)
    {
        _credentials = credentials;
    }

    /// <summary>
    /// Transcribe a 1:1 session from mic and optional system audio PCM sidecars.
    /// Automatically decrypts .enc.pcm files using the device encryption key.
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

        // Create encryptor for decrypting .enc.pcm files
        AesGcmEncryptor? encryptor = null;
        var keyBytes = _credentials.GetOrCreateDeviceEncryptionKey();
        if (keyBytes != null)
            encryptor = new AesGcmEncryptor(keyBytes, "device-key");

        // Preprocess mic audio
        progress?.Report(new TranscriptionProgress(
            TranscriptionState.Preprocessing, 0, "Preprocessing mic audio..."));

        var micAudio = await AudioPreprocessor.PreprocessMicPcmAsync(micPath, encryptor: encryptor);
        ct.ThrowIfCancellationRequested();

        // Transcribe mic
        progress?.Report(new TranscriptionProgress(
            TranscriptionState.Transcribing, 0.1, "Transcribing mic audio..."));

        var micRaw = await WhisperTranscriber.TranscribeAsync(modelPath, micAudio, ct,
            onRegionProgress: (current, total) =>
                progress?.Report(new TranscriptionProgress(
                    TranscriptionState.Transcribing,
                    0.1 + 0.4 * ((double)current / total),
                    $"Transcribing mic audio (region {current}/{total})...")));

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

            var sysAudio = await AudioPreprocessor.PreprocessSystemPcmAsync(systemPath, encryptor: encryptor);
            ct.ThrowIfCancellationRequested();

            progress?.Report(new TranscriptionProgress(
                TranscriptionState.Transcribing, 0.6, "Transcribing system audio..."));

            var sysRaw = await WhisperTranscriber.TranscribeAsync(modelPath, sysAudio, ct,
                onRegionProgress: (current, total) =>
                    progress?.Report(new TranscriptionProgress(
                        TranscriptionState.Transcribing,
                        0.6 + 0.35 * ((double)current / total),
                        $"Transcribing system audio (region {current}/{total})...")));

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
