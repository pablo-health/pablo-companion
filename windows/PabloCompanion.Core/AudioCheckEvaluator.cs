namespace PabloCompanion.Core;

/// <summary>Which part of the audio check a level sample belongs to.</summary>
public enum AudioCheckPhase
{
    /// <summary>Pablo's greeting is playing through the PC's output.</summary>
    Greeting,

    /// <summary>The clinician has been asked to say hello.</summary>
    YourTurn,
}

/// <summary>
/// Judges the first-use audio check from live levels. Uses the same thresholds
/// as <see cref="ClientAudioMonitor"/>, so "Pablo heard your computer" here means
/// exactly what "hearing client" means in a session. Mirrors
/// <c>AudioCheckEvaluator.swift</c>.
/// </summary>
public sealed class AudioCheckEvaluator
{
    /// <summary>
    /// Speaking needed to count as "heard you": longer than a cough, a click or
    /// a door, comfortably shorter than "Hello, Pablo".
    /// </summary>
    public static readonly TimeSpan SpeechNeeded = TimeSpan.FromSeconds(1);

    /// <summary>
    /// How far above the room's background speaking has to rise. Steady noise
    /// (a fan, an air conditioner) sits at the background and never counts.
    /// </summary>
    public const float AboveBackgroundDecibels = 10f;

    private TimeSpan _speech;

    // Quietest the mic has been during the clinician's turn. Silence before
    // they start, or the pauses between words, pull it down to the room.
    private float? _backgroundDecibels;
    private DateTimeOffset? _lastSampleAt;

    public bool HeardComputer { get; private set; }

    public bool HeardYou { get; private set; }

    public bool Passed => HeardComputer && HeardYou;

    /// <summary>Feed one level update (linear RMS, 0-1, as AudioCaptureKit reports).</summary>
    public void Record(float micRms, float systemRms, AudioCheckPhase phase, DateTimeOffset now)
    {
        var gap = _lastSampleAt is { } last
            ? TimeSpan.FromTicks(Math.Clamp((now - last).Ticks, 0, ClientAudioMonitor.MaxSampleGap.Ticks))
            : TimeSpan.Zero;
        _lastSampleAt = now;

        switch (phase)
        {
            case AudioCheckPhase.Greeting:
                // The greeting reaches the loopback capture exactly as a client's
                // voice would. The mic is ignored here: it hears the speakers too.
                if (ClientAudioMonitor.Decibels(systemRms) >= ClientAudioMonitor.ClientDecibels)
                    HeardComputer = true;
                break;

            case AudioCheckPhase.YourTurn:
                var level = ClientAudioMonitor.Decibels(micRms);
                var background = MathF.Min(_backgroundDecibels ?? level, level);
                _backgroundDecibels = background;
                var speaking = level >= ClientAudioMonitor.SpeechDecibels
                    && level >= background + AboveBackgroundDecibels;
                if (speaking)
                {
                    _speech += gap;
                    if (_speech >= SpeechNeeded) HeardYou = true;
                }
                break;
        }
    }
}
