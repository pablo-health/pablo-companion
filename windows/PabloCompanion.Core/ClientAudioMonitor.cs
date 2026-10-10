namespace PabloCompanion.Core;

/// <summary>Whether the client's side of the call is reaching the recording.</summary>
public enum ClientAudioStatus
{
    /// <summary>Too early to tell: nobody has said enough yet.</summary>
    Listening,

    /// <summary>Client audio has been heard recently.</summary>
    HearingClient,

    /// <summary>The therapist is talking but nothing is arriving from the call.</summary>
    NoClientAudio,
}

/// <summary>
/// Watches live capture levels and decides whether the client's side of the
/// call is reaching the recording. Mirrors <c>ClientAudioMonitor.swift</c>.
///
/// A loopback capture that exists is not the same as one that hears the call:
/// the call can be playing on a different output device, through a Bluetooth
/// hands-free profile, or in a muted tab, and the recording then holds only the
/// therapist. This judges what actually arrives.
///
/// Fed <c>(mic, system, time)</c> samples and free of UI types, so the
/// thresholds are unit-tested and a first-use audio check can share the same
/// judgement.
/// </summary>
public sealed class ClientAudioMonitor
{
    /// <summary>Mic level that counts as the therapist speaking.</summary>
    public const float SpeechDecibels = -45f;

    /// <summary>
    /// System level that counts as hearing the call. Below speech: a remote
    /// voice through a call app is often quiet.
    /// </summary>
    public const float ClientDecibels = -55f;

    /// <summary>Therapist speech needed before an absent client is a problem.</summary>
    public static readonly TimeSpan SpeechBeforeWarning = TimeSpan.FromSeconds(5);

    /// <summary>
    /// Never warn sooner than this: the client may still be in the waiting
    /// room, and an empty call outputs real digital silence.
    /// </summary>
    public static readonly TimeSpan EarliestWarning = TimeSpan.FromSeconds(45);

    /// <summary>
    /// After the client has been heard, this much silence from the call, while
    /// the therapist keeps talking, means it was lost.
    /// </summary>
    public static readonly TimeSpan LostClientAfter = TimeSpan.FromSeconds(120);

    /// <summary>Therapist speech within <see cref="LostClientAfter"/> needed to call the client lost.</summary>
    public static readonly TimeSpan SpeechBeforeLostWarning = TimeSpan.FromSeconds(20);

    /// <summary>
    /// Gaps longer than this between samples (sleep, a stalled timer) count as
    /// this much, so one late sample can't add a minute of speech.
    /// </summary>
    public static readonly TimeSpan MaxSampleGap = TimeSpan.FromSeconds(1);

    private DateTimeOffset? _startedAt;
    private DateTimeOffset? _lastSampleAt;
    private DateTimeOffset? _lastClientHeardAt;

    // Therapist speech since the client was last heard (or since start).
    private TimeSpan _speechSinceClient;

    public ClientAudioStatus Status { get; private set; } = ClientAudioStatus.Listening;

    /// <summary>Feed one level update (linear RMS, 0-1, as AudioCaptureKit reports).</summary>
    public void Record(float micRms, float systemRms, DateTimeOffset now)
    {
        var start = _startedAt ?? now;
        _startedAt = start;
        var gap = _lastSampleAt is { } last
            ? TimeSpan.FromTicks(Math.Clamp((now - last).Ticks, 0, MaxSampleGap.Ticks))
            : TimeSpan.Zero;
        _lastSampleAt = now;

        if (Decibels(systemRms) >= ClientDecibels)
        {
            _lastClientHeardAt = now;
            _speechSinceClient = TimeSpan.Zero;
            Status = ClientAudioStatus.HearingClient;
            return;
        }
        if (Decibels(micRms) >= SpeechDecibels)
            _speechSinceClient += gap;

        if (_lastClientHeardAt is { } heard)
        {
            var lost = now - heard >= LostClientAfter && _speechSinceClient >= SpeechBeforeLostWarning;
            Status = lost ? ClientAudioStatus.NoClientAudio : ClientAudioStatus.HearingClient;
        }
        else
        {
            var warn = now - start >= EarliestWarning && _speechSinceClient >= SpeechBeforeWarning;
            Status = warn ? ClientAudioStatus.NoClientAudio : ClientAudioStatus.Listening;
        }
    }

    /// <summary>Start over: a new recording, or resuming from pause.</summary>
    public void Reset()
    {
        _startedAt = null;
        _lastSampleAt = null;
        _lastClientHeardAt = null;
        _speechSinceClient = TimeSpan.Zero;
        Status = ClientAudioStatus.Listening;
    }

    /// <summary>Linear RMS to dBFS; silence is negative infinity.</summary>
    public static float Decibels(float rms) =>
        rms > 0 ? 20f * MathF.Log10(MathF.Min(rms, 1f)) : float.NegativeInfinity;
}
