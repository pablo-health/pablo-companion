using Whisper.net;

namespace PabloCompanion.Services;

/// <summary>
/// Whisper-based ASR with VAD splitting.
/// Port of core/src/whisper_transcriber.rs.
/// </summary>
public static class WhisperTranscriber
{
    private const int WhisperSampleRate = 16000;
    private const float SilenceRmsThreshold = 0.01f;
    private const int VadWindowSamples = (WhisperSampleRate * 20) / 1000; // 320
    private const int MinSilenceGapMs = 500;
    private const int MinRegionSamples = WhisperSampleRate / 10; // 1600 = 100ms

    /// <summary>
    /// Transcribe 16 kHz mono float audio using a Whisper GGML model.
    /// Audio is split at silence boundaries before transcription.
    /// </summary>
    public static async Task<RawSegment[]> TranscribeAsync(string modelPath, float[] audio,
        CancellationToken ct = default, Action<int, int>? onRegionProgress = null)
    {
        if (audio.Length == 0)
            return [];

        return await Task.Factory.StartNew(
            () => RunTranscription(modelPath, audio, ct, onRegionProgress),
            ct, TaskCreationOptions.LongRunning, TaskScheduler.Default);
    }

    private static RawSegment[] RunTranscription(string modelPath, float[] audio,
        CancellationToken ct, Action<int, int>? onRegionProgress)
    {
        var regions = DetectSpeechRegions(audio);
        if (regions.Length == 0)
            return [];

        using var factory = WhisperFactory.FromPath(modelPath);
        var segments = new List<RawSegment>();

        for (int i = 0; i < regions.Length; i++)
        {
            ct.ThrowIfCancellationRequested();
            onRegionProgress?.Invoke(i + 1, regions.Length);

            var region = regions[i];
            var chunk = audio.AsSpan(region.StartSample,
                Math.Min(region.EndSample, audio.Length) - region.StartSample).ToArray();
            long offsetMs = region.StartSample * 1000L / WhisperSampleRate;

            var chunkSegments = TranscribeChunk(factory, chunk, offsetMs, ct);
            segments.AddRange(chunkSegments);
        }

        return [.. segments];
    }

    private static List<RawSegment> TranscribeChunk(WhisperFactory factory, float[] audio,
        long offsetMs, CancellationToken ct)
    {
        var segments = new List<RawSegment>();

        using var processor = factory.CreateBuilder()
            .WithLanguage("en")
            .WithBeamSearchSamplingStrategy()
            .ParentBuilder
            .WithTokenTimestamps()
            .WithSegmentEventHandler((seg) =>
            {
                long startMs = (long)seg.Start.TotalMilliseconds + offsetMs;
                long endMs = (long)seg.End.TotalMilliseconds + offsetMs;
                string text = CleanText(seg.Text);

                if (!string.IsNullOrEmpty(text))
                    segments.Add(new RawSegment(startMs, endMs, text));
            })
            .Build();

        ct.ThrowIfCancellationRequested();
        processor.Process(audio);

        return segments;
    }

    /// <summary>
    /// Scan audio for contiguous speech regions using RMS energy VAD.
    /// Port of detect_speech_regions from whisper_transcriber.rs.
    /// </summary>
    internal static SpeechRegion[] DetectSpeechRegions(float[] audio)
    {
        int minSilenceWindows = (MinSilenceGapMs * WhisperSampleRate) / (1000 * VadWindowSamples);
        var regions = new List<SpeechRegion>();
        bool inSpeech = false;
        int regionStart = 0;
        int silenceCount = 0;

        int pos = 0;
        while (pos + VadWindowSamples <= audio.Length)
        {
            // Calculate RMS for this window
            double sumSq = 0;
            for (int i = pos; i < pos + VadWindowSamples; i++)
            {
                double s = audio[i];
                sumSq += s * s;
            }
            float rms = (float)Math.Sqrt(sumSq / VadWindowSamples);
            bool isSpeech = rms >= SilenceRmsThreshold;

            if (isSpeech)
            {
                if (!inSpeech)
                {
                    regionStart = pos;
                    inSpeech = true;
                }
                silenceCount = 0;
            }
            else if (inSpeech)
            {
                silenceCount++;
                if (silenceCount >= minSilenceWindows)
                {
                    int regionEnd = pos - (silenceCount - 1) * VadWindowSamples;
                    regions.Add(new SpeechRegion(regionStart, regionEnd));
                    inSpeech = false;
                    silenceCount = 0;
                }
            }

            pos += VadWindowSamples;
        }

        // Close any open region at end of audio
        if (inSpeech)
        {
            regions.Add(new SpeechRegion(regionStart, audio.Length));
        }

        // Drop regions shorter than Whisper's minimum (100ms)
        return regions.Where(r => r.EndSample - r.StartSample >= MinRegionSamples).ToArray();
    }

    /// <summary>
    /// Strip leading/trailing quotes and whitespace that Whisper sometimes adds.
    /// </summary>
    internal static string CleanText(string raw)
    {
        var trimmed = raw.Trim();
        if (trimmed.Length >= 2 && trimmed[0] == '"' && trimmed[^1] == '"')
            return trimmed[1..^1].Trim();
        if (trimmed.StartsWith('"'))
            return trimmed[1..].Trim();
        if (trimmed.EndsWith('"'))
            return trimmed[..^1].Trim();
        return trimmed;
    }
}

public sealed record RawSegment(long StartMs, long EndMs, string Text);

internal sealed record SpeechRegion(int StartSample, int EndSample);
