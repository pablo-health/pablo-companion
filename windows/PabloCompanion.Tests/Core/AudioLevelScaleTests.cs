using PabloCompanion.Core;
using Xunit;

namespace PabloCompanion.Tests.Core;

/// <summary>Port of LevelMeterTests.swift: the meters' decibel mapping.</summary>
public class AudioLevelScaleTests
{
    [Fact]
    public void SilenceReadsEmpty()
    {
        Assert.Equal(0f, AudioLevelScale.DisplayFraction(0));
        Assert.Equal(0f, AudioLevelScale.DisplayFraction(0.001f), 3); // -60 dBFS, the floor
        Assert.Equal(0f, AudioLevelScale.DisplayFraction(0.0001f)); // -80 dBFS, below the floor
    }

    [Fact]
    public void FullScaleReadsFull()
    {
        Assert.Equal(1f, AudioLevelScale.DisplayFraction(1));
        Assert.Equal(1f, AudioLevelScale.DisplayFraction(1.5f));
    }

    [Fact]
    public void NormalSpeechFillsAboutHalfTheBar()
    {
        // Regression: drawn linearly, speech-level RMS (~0.03) filled 3% of the
        // bar and the meters looked dead mid-session. -30 dBFS is mid-scale.
        var fraction = AudioLevelScale.DisplayFraction(0.0316f);
        Assert.True(Math.Abs(fraction - 0.5f) < 0.01f, $"fraction was {fraction}");
    }

    [Fact]
    public void AQuietFarEndVoiceStillRegisters()
    {
        // About -45 dBFS: a soft remote speaker should still visibly move the bar.
        Assert.True(AudioLevelScale.DisplayFraction(0.0056f) > 0.2f);
    }

    [Fact]
    public void LouderIsAlwaysHigher()
    {
        float[] levels = [0.001f, 0.01f, 0.05f, 0.1f, 0.5f, 1f];
        var fractions = levels.Select(AudioLevelScale.DisplayFraction).ToArray();
        Assert.Equal(fractions.Order().ToArray(), fractions);
        Assert.Equal(fractions.Length, fractions.Distinct().Count());
    }

    [Fact]
    public void NotANumberReadsEmpty()
    {
        Assert.Equal(0f, AudioLevelScale.DisplayFraction(float.NaN));
    }
}
