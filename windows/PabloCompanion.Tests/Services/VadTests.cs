using PabloCompanion.Services;

namespace PabloCompanion.Tests.Services;

public class VadTests
{
    private static float[] MakeSine(int numSamples, float amplitude)
    {
        var audio = new float[numSamples];
        for (int i = 0; i < numSamples; i++)
            audio[i] = MathF.Sin(i / 16000.0f * MathF.Tau * 440) * amplitude;
        return audio;
    }

    [Fact]
    public void SilenceProducesNoRegions()
    {
        var silence = new float[48000]; // 3 seconds of silence
        var regions = WhisperTranscriber.DetectSpeechRegions(silence);
        Assert.Empty(regions);
    }

    [Fact]
    public void ContinuousSpeechSingleRegion()
    {
        var speech = MakeSine(48000, 0.1f); // 3 seconds of speech
        var regions = WhisperTranscriber.DetectSpeechRegions(speech);
        Assert.Single(regions);
        Assert.Equal(0, regions[0].StartSample);
    }

    [Fact]
    public void TwoUtterancesWithLongGap()
    {
        // 1s speech, 1s silence, 1s speech
        var audio = new float[48000];
        var speech1 = MakeSine(16000, 0.1f);
        var speech2 = MakeSine(16000, 0.1f);

        Array.Copy(speech1, 0, audio, 0, 16000);
        // 16000-32000 = silence (already zeros)
        Array.Copy(speech2, 0, audio, 32000, 16000);

        var regions = WhisperTranscriber.DetectSpeechRegions(audio);
        Assert.Equal(2, regions.Length);

        // Second region should start at ~2s
        int secondStartMs = regions[1].StartSample * 1000 / 16000;
        Assert.InRange(secondStartMs, 1800, 2200);
    }

    [Fact]
    public void ShortPauseWithinSpeechNotSplit()
    {
        // 1s speech, 200ms pause (< 500ms), 1s speech → single region
        int speechSamples = 16000;
        int pauseSamples = 3200; // 200ms
        var audio = new float[speechSamples + pauseSamples + speechSamples];

        var speech = MakeSine(speechSamples, 0.1f);
        Array.Copy(speech, 0, audio, 0, speechSamples);
        // Pause is zeros
        Array.Copy(speech, 0, audio, speechSamples + pauseSamples, speechSamples);

        var regions = WhisperTranscriber.DetectSpeechRegions(audio);
        Assert.Single(regions);
    }

    [Fact]
    public void SpeechWithLeadingSilence()
    {
        // 2s silence, then 1s speech
        var audio = new float[48000];
        var speech = MakeSine(16000, 0.1f);
        Array.Copy(speech, 0, audio, 32000, 16000);

        var regions = WhisperTranscriber.DetectSpeechRegions(audio);
        Assert.Single(regions);

        int startMs = regions[0].StartSample * 1000 / 16000;
        Assert.InRange(startMs, 1980, 2020);
    }

    [Fact]
    public void ThreeUtterances()
    {
        // speech, silence, speech, silence, speech
        int speechLen = 16000;
        int silenceLen = 16000;
        var audio = new float[speechLen * 3 + silenceLen * 2];

        var speech = MakeSine(speechLen, 0.1f);
        for (int i = 0; i < 3; i++)
        {
            int offset = i * (speechLen + silenceLen);
            Array.Copy(speech, 0, audio, offset, speechLen);
        }

        var regions = WhisperTranscriber.DetectSpeechRegions(audio);
        Assert.Equal(3, regions.Length);
    }
}
