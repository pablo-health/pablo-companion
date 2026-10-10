namespace PabloCompanion.Core;

/// <summary>
/// Maps the linear RMS AudioCaptureKit reports (0-1) onto a level meter.
/// Mirrors <c>LevelMeter.displayFraction(forRMS:)</c> on macOS.
///
/// Drawn linearly, speech (RMS around 0.01-0.1) filled only a few percent of
/// the bar and the meters looked dead mid-session. Meters are drawn on a
/// decibel scale instead, as audio meters conventionally are.
/// </summary>
public static class AudioLevelScale
{
    /// <summary>Quietest level that registers; anything below reads as empty.</summary>
    public const float FloorDecibels = -60f;

    /// <summary>
    /// <see cref="FloorDecibels"/> dBFS and below maps to 0, 0 dBFS to 1,
    /// linear in decibels between.
    /// </summary>
    public static float DisplayFraction(float rms)
    {
        if (!(rms > 0)) return 0;
        var decibels = 20f * MathF.Log10(MathF.Min(rms, 1f));
        return Math.Clamp((decibels - FloorDecibels) / -FloorDecibels, 0f, 1f);
    }
}
