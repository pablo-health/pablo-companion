using PabloCompanion.Core;
using Xunit;

namespace PabloCompanion.Tests.Core;

/// <summary>Port of ClientAudioMonitorTests.swift, plus the threshold edges.</summary>
public class ClientAudioMonitorTests
{
    private const float Speech = 0.05f; // about -26 dBFS
    private const float QuietClient = 0.003f; // about -50 dBFS
    private const float BarelyAudibleClient = 0.002f; // about -54 dBFS, just above the -55 dB line
    private const float RoomNoise = 0.0005f; // about -66 dBFS
    private static readonly DateTimeOffset Start = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);

    private static DateTimeOffset At(int tenths) => Start.AddTicks(tenths * TimeSpan.TicksPerSecond / 10);

    /// <summary>Feeds samples at 10 Hz for times in [from, to), in tenths of a second.</summary>
    private static void Feed(ClientAudioMonitor monitor, int fromTenths, int toTenths, float mic, float system)
    {
        for (var t = fromTenths; t < toTenths; t++)
            monitor.Record(mic, system, At(t));
    }

    [Fact]
    public void WarnsWhenTheTherapistTalksAndNothingArrivesFromTheCall()
    {
        var monitor = new ClientAudioMonitor();
        Feed(monitor, 0, 500, Speech, 0);

        Assert.Equal(ClientAudioStatus.NoClientAudio, monitor.Status);
    }

    [Fact]
    public void DoesNotWarnBeforeTheClientCouldHaveJoined()
    {
        var monitor = new ClientAudioMonitor();
        Feed(monitor, 0, 440, Speech, 0);
        monitor.Record(Speech, 0, At(440)); // 44 s

        Assert.Equal(ClientAudioStatus.Listening, monitor.Status);
    }

    [Fact]
    public void WarnsAtFortyFiveSecondsOnceFiveSecondsOfSpeechHaveBeenHeard()
    {
        var monitor = new ClientAudioMonitor();
        Feed(monitor, 0, 400, RoomNoise, 0);
        Feed(monitor, 400, 450, Speech, 0); // 40.0-44.9 s: 5.0 s of speech by 44.9
        Assert.Equal(ClientAudioStatus.Listening, monitor.Status);

        monitor.Record(Speech, 0, At(450)); // 45 s

        Assert.Equal(ClientAudioStatus.NoClientAudio, monitor.Status);
    }

    [Fact]
    public void DoesNotWarnAtFortyFiveSecondsWithLessThanFiveSecondsOfSpeech()
    {
        var monitor = new ClientAudioMonitor();
        Feed(monitor, 0, 410, RoomNoise, 0);
        Feed(monitor, 410, 451, Speech, 0); // 4.1 s of speech by 45 s

        Assert.Equal(ClientAudioStatus.Listening, monitor.Status);
    }

    [Fact]
    public void DoesNotWarnWhileTheTherapistIsSilentToo()
    {
        // Waiting in an empty call: neither side is talking.
        var monitor = new ClientAudioMonitor();
        Feed(monitor, 0, 900, RoomNoise, 0);

        Assert.Equal(ClientAudioStatus.Listening, monitor.Status);
    }

    [Fact]
    public void AQuietRemoteVoiceCountsAsHearingTheClient()
    {
        var monitor = new ClientAudioMonitor();
        Feed(monitor, 0, 300, Speech, 0);
        Feed(monitor, 300, 310, 0, QuietClient);

        Assert.Equal(ClientAudioStatus.HearingClient, monitor.Status);
    }

    [Fact]
    public void AClientAtMinusFiftyFourDecibelsCountsAsHeard()
    {
        Assert.True(ClientAudioMonitor.Decibels(BarelyAudibleClient) >= ClientAudioMonitor.ClientDecibels);
        Assert.True(ClientAudioMonitor.Decibels(BarelyAudibleClient) < -53.9f);

        var monitor = new ClientAudioMonitor();
        Feed(monitor, 0, 500, Speech, 0);
        Assert.Equal(ClientAudioStatus.NoClientAudio, monitor.Status);

        monitor.Record(Speech, BarelyAudibleClient, At(500));

        Assert.Equal(ClientAudioStatus.HearingClient, monitor.Status);
    }

    [Fact]
    public void TheWarningClearsOnceTheClientIsHeard()
    {
        var monitor = new ClientAudioMonitor();
        Feed(monitor, 0, 500, Speech, 0);
        Assert.Equal(ClientAudioStatus.NoClientAudio, monitor.Status);

        Feed(monitor, 500, 510, 0, Speech);

        Assert.Equal(ClientAudioStatus.HearingClient, monitor.Status);
    }

    [Fact]
    public void WarnsAgainIfTheClientIsLostMidSession()
    {
        // Call audio moved to another output device mid-session.
        var monitor = new ClientAudioMonitor();
        Feed(monitor, 0, 100, 0, Speech);
        Feed(monitor, 100, 1400, Speech, 0);

        Assert.Equal(ClientAudioStatus.NoClientAudio, monitor.Status);
    }

    [Fact]
    public void TheClientIsLostAfterOneHundredTwentySecondsOfCallSilence()
    {
        var monitor = new ClientAudioMonitor();
        Feed(monitor, 0, 101, 0, Speech); // last heard at 10.0 s
        Feed(monitor, 101, 1300, Speech, 0); // up to 129.9 s: 119.9 s since heard
        Assert.Equal(ClientAudioStatus.HearingClient, monitor.Status);

        monitor.Record(Speech, 0, At(1300)); // 130 s: 120 s since heard

        Assert.Equal(ClientAudioStatus.NoClientAudio, monitor.Status);
    }

    [Fact]
    public void TheClientIsLostOnlyAfterTwentySecondsOfSpeech()
    {
        var monitor = new ClientAudioMonitor();
        Feed(monitor, 0, 101, 0, Speech); // last heard at 10.0 s
        Feed(monitor, 101, 291, Speech, 0); // 19.0 s of speech
        Feed(monitor, 291, 1400, RoomNoise, 0); // well past 120 s of call silence
        Assert.Equal(ClientAudioStatus.HearingClient, monitor.Status);

        Feed(monitor, 1400, 1410, Speech, 0); // the 20th second

        Assert.Equal(ClientAudioStatus.NoClientAudio, monitor.Status);
    }

    [Fact]
    public void ALongListeningPauseIsNotALostClient()
    {
        // Client heard, then a long stretch where nobody says much.
        var monitor = new ClientAudioMonitor();
        Feed(monitor, 0, 100, 0, Speech);
        Feed(monitor, 100, 1600, RoomNoise, 0);

        Assert.Equal(ClientAudioStatus.HearingClient, monitor.Status);
    }

    [Fact]
    public void ASingleLateSampleCannotAddAMinuteOfSpeech()
    {
        var monitor = new ClientAudioMonitor();
        monitor.Record(Speech, 0, Start);
        monitor.Record(Speech, 0, Start.AddSeconds(60));

        Assert.Equal(ClientAudioStatus.Listening, monitor.Status);
    }

    [Fact]
    public void SampleGapsCountAtMostOneSecond()
    {
        // Speech sampled every 3 s up to 57 s: 19 gaps, each clamped to 1 s, is
        // 19 s of speech, not 57. Short of the 20 s that loses a client...
        var monitor = new ClientAudioMonitor();
        monitor.Record(0, Speech, Start);
        for (var s = 3; s <= 57; s += 3)
            monitor.Record(Speech, 0, Start.AddSeconds(s));
        monitor.Record(RoomNoise, 0, Start.AddSeconds(120));
        Assert.Equal(ClientAudioStatus.HearingClient, monitor.Status);

        // ...until one more clamped second of speech.
        monitor.Record(Speech, 0, Start.AddSeconds(125));
        Assert.Equal(ClientAudioStatus.NoClientAudio, monitor.Status);
    }

    [Fact]
    public void ResetStartsOver()
    {
        var monitor = new ClientAudioMonitor();
        Feed(monitor, 0, 500, Speech, 0);
        monitor.Reset();

        Assert.Equal(ClientAudioStatus.Listening, monitor.Status);
        Feed(monitor, 1000, 1100, Speech, 0);
        Assert.Equal(ClientAudioStatus.Listening, monitor.Status);
    }
}
