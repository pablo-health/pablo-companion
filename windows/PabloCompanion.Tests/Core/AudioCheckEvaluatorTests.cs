using PabloCompanion.Core;

namespace PabloCompanion.Tests.Core;

/// <summary>Port of AudioCheckEvaluatorTests.swift.</summary>
public class AudioCheckEvaluatorTests
{
    private const float Voice = 0.05f; // about -26 dBFS
    private const float QuietRoom = 0.001f; // about -60 dBFS
    private static readonly DateTimeOffset Start = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);

    /// <summary>Feeds samples at 10 Hz for times in [from, from + seconds), in tenths of a second.</summary>
    private static void Feed(
        AudioCheckEvaluator evaluator, AudioCheckPhase phase, int fromTenths, int tenths, float mic, float system)
    {
        for (var t = fromTenths; t < fromTenths + tenths; t++)
            evaluator.Record(mic, system, phase, Start.AddTicks(t * TimeSpan.TicksPerSecond / 10));
    }

    /// <summary>A beat of room quiet, then about a second and a half of speaking.</summary>
    private static void AnswerHello(AudioCheckEvaluator evaluator, int fromTenths)
    {
        Feed(evaluator, AudioCheckPhase.YourTurn, fromTenths, 5, QuietRoom, 0);
        Feed(evaluator, AudioCheckPhase.YourTurn, fromTenths + 5, 15, Voice, 0);
    }

    [Fact]
    public void PassesWhenTheGreetingIsCapturedAndTheClinicianAnswers()
    {
        var evaluator = new AudioCheckEvaluator();
        Feed(evaluator, AudioCheckPhase.Greeting, 0, 50, Voice, Voice);
        AnswerHello(evaluator, 50);

        Assert.True(evaluator.HeardComputer);
        Assert.True(evaluator.HeardYou);
        Assert.True(evaluator.Passed);
    }

    [Fact]
    public void ASilentLoopbackFailsTheComputerStep()
    {
        var evaluator = new AudioCheckEvaluator();
        Feed(evaluator, AudioCheckPhase.Greeting, 0, 50, Voice, 0);
        AnswerHello(evaluator, 50);

        Assert.False(evaluator.HeardComputer);
        Assert.True(evaluator.HeardYou);
        Assert.False(evaluator.Passed);
    }

    [Fact]
    public void TheMicHearingTheGreetingDoesNotCountAsTheClinician()
    {
        // The mic picks Pablo up through the speakers; only the clinician's turn counts.
        var evaluator = new AudioCheckEvaluator();
        Feed(evaluator, AudioCheckPhase.Greeting, 0, 50, Voice, Voice);
        Feed(evaluator, AudioCheckPhase.YourTurn, 50, 80, 0.0005f, 0);

        Assert.True(evaluator.HeardComputer);
        Assert.False(evaluator.HeardYou);
    }

    [Fact]
    public void ACoughIsNotAHello()
    {
        var evaluator = new AudioCheckEvaluator();
        Feed(evaluator, AudioCheckPhase.YourTurn, 0, 5, QuietRoom, 0);
        Feed(evaluator, AudioCheckPhase.YourTurn, 5, 4, Voice, 0);
        Feed(evaluator, AudioCheckPhase.YourTurn, 9, 30, QuietRoom, 0);

        Assert.False(evaluator.HeardYou);
    }

    [Fact]
    public void SteadyNoiseNeverCountsAsSpeaking()
    {
        // A loud fan right by the mic: above -45 dBFS, but it is the room's
        // background, not someone talking.
        var evaluator = new AudioCheckEvaluator();
        Feed(evaluator, AudioCheckPhase.YourTurn, 0, 80, 0.03f, 0);

        Assert.False(evaluator.HeardYou);
    }

    [Fact]
    public void ASecondOfSpeakingTenDecibelsAboveTheBackgroundPasses()
    {
        // Background about -44 dBFS, speaking 10 dB above it (plus a hair for
        // float rounding).
        var background = 0.006f;
        var speaking = background * MathF.Pow(10, (AudioCheckEvaluator.AboveBackgroundDecibels + 0.01f) / 20);
        var evaluator = new AudioCheckEvaluator();
        Feed(evaluator, AudioCheckPhase.YourTurn, 0, 5, background, 0);
        // Ten speaking samples, each 0.1 s after the last: one second of speaking.
        Feed(evaluator, AudioCheckPhase.YourTurn, 5, 10, speaking, 0);

        Assert.True(evaluator.HeardYou);
    }

    [Fact]
    public void JustUnderASecondOfSpeakingIsNotEnough()
    {
        var evaluator = new AudioCheckEvaluator();
        Feed(evaluator, AudioCheckPhase.YourTurn, 0, 5, QuietRoom, 0);
        Feed(evaluator, AudioCheckPhase.YourTurn, 5, 9, Voice, 0); // 0.9 s

        Assert.False(evaluator.HeardYou);
    }

    [Fact]
    public void SpeakingOverANoisyRoomStillCounts()
    {
        var evaluator = new AudioCheckEvaluator();
        Feed(evaluator, AudioCheckPhase.YourTurn, 0, 5, 0.006f, 0); // about -44 dBFS fan
        Feed(evaluator, AudioCheckPhase.YourTurn, 5, 15, 0.08f, 0); // about -22 dBFS voice

        Assert.True(evaluator.HeardYou);
    }

    [Fact]
    public void SpeakingStraightAwayCountsOnceThereIsAPause()
    {
        // No quiet before the first word: the gap between words gives the
        // background, and the speaking after it counts.
        var evaluator = new AudioCheckEvaluator();
        Feed(evaluator, AudioCheckPhase.YourTurn, 0, 6, Voice, 0);
        Feed(evaluator, AudioCheckPhase.YourTurn, 6, 3, QuietRoom, 0);
        Feed(evaluator, AudioCheckPhase.YourTurn, 9, 13, Voice, 0);

        Assert.True(evaluator.HeardYou);
    }

    [Fact]
    public void SoundOnTheSystemDuringYourTurnIsIgnored()
    {
        var evaluator = new AudioCheckEvaluator();
        Feed(evaluator, AudioCheckPhase.YourTurn, 0, 30, 0, Voice);

        Assert.False(evaluator.HeardComputer);
    }

    [Fact]
    public void AQuietButAudibleGreetingCountsAtTheClientThreshold()
    {
        var evaluator = new AudioCheckEvaluator();
        Feed(evaluator, AudioCheckPhase.Greeting, 0, 10, 0, 0.002f); // about -54 dBFS

        Assert.True(evaluator.HeardComputer);
    }
}
