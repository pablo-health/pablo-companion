using PabloCompanion.Services;

namespace PabloCompanion.Tests.Services;

public class GoogleMeetRendererTests
{
    private static GoogleMeetOptions Opts() => new("April 3, 2024", "Dr. Lee", "Alex");

    private static TranscriptResult MakeTranscript(params TranscriptSegment[] segments) =>
        new("test-session", segments);

    [Fact]
    public void EmptyTranscriptRendersHeader()
    {
        var t = MakeTranscript();
        var output = GoogleMeetRenderer.Render(t, Opts());

        Assert.StartsWith("Google Meet Transcript", output);
        Assert.Contains("Session Date: April 3, 2024", output);
        Assert.Contains("Duration: 0:00", output);
        Assert.Contains("Speakers: 0", output);
    }

    [Fact]
    public void SingleTurnRendersCorrectly()
    {
        var t = MakeTranscript(
            new TranscriptSegment(SpeakerLabel.Therapist, 8.0, 12.0, "Good afternoon."));
        var output = GoogleMeetRenderer.Render(t, Opts());

        Assert.Contains("[00:00:08]", output);
        Assert.Contains("Dr. Lee: Good afternoon.", output);
        Assert.Contains("[Session ends 00:00:12]", output);
        Assert.Contains("Speakers: 1", output);
        Assert.Contains("Dr. Lee (Therapist)", output);
    }

    [Fact]
    public void AdjacentSameSpeakerWithinMergeGapMerges()
    {
        var t = MakeTranscript(
            new TranscriptSegment(SpeakerLabel.Therapist, 0.0, 2.0, "Hello"),
            new TranscriptSegment(SpeakerLabel.Therapist, 3.0, 5.0, "world.")); // gap=1.0s <=1.5s
        var output = GoogleMeetRenderer.Render(t, Opts());

        Assert.Contains("Dr. Lee: Hello world.", output);
        // Should only have one timestamp
        Assert.Equal(1, CountOccurrences(output, "[00:00:00]"));
    }

    [Fact]
    public void PauseOver3sSameSpeakerCreatesNewTurn()
    {
        var t = MakeTranscript(
            new TranscriptSegment(SpeakerLabel.Therapist, 0.0, 2.0, "First."),
            new TranscriptSegment(SpeakerLabel.Therapist, 6.0, 8.0, "Second.")); // gap=4.0s >3.0s
        var output = GoogleMeetRenderer.Render(t, Opts());

        Assert.Contains("[00:00:00]", output);
        Assert.Contains("[00:00:06]", output);
    }

    [Fact]
    public void SpeakerChangeCreatesNewTurn()
    {
        var t = MakeTranscript(
            new TranscriptSegment(SpeakerLabel.Therapist, 0.0, 3.0, "How are you?"),
            new TranscriptSegment(SpeakerLabel.Client, 4.0, 7.0, "I'm okay."));
        var output = GoogleMeetRenderer.Render(t, Opts());

        Assert.Contains("Dr. Lee: How are you?", output);
        Assert.Contains("Alex: I'm okay.", output);
        Assert.Contains("Speakers: 2", output);
    }

    [Fact]
    public void TwoDigitHoursInTimestamps()
    {
        var t = MakeTranscript(
            new TranscriptSegment(SpeakerLabel.Client, 4000.0, 4005.0, "Late in session."));
        var output = GoogleMeetRenderer.Render(t, Opts());

        Assert.Contains("[01:06:40]", output);
    }

    [Fact]
    public void DurationFormats()
    {
        Assert.Equal("0:00", GoogleMeetRenderer.FormatDuration(0));
        Assert.Equal("5:14", GoogleMeetRenderer.FormatDuration(314));
        Assert.Equal("1:02:00", GoogleMeetRenderer.FormatDuration(3720));
    }

    private static int CountOccurrences(string text, string pattern)
    {
        int count = 0;
        int index = 0;
        while ((index = text.IndexOf(pattern, index, StringComparison.Ordinal)) >= 0)
        {
            count++;
            index += pattern.Length;
        }
        return count;
    }
}
