using System.Text;

namespace PabloCompanion.Services;

/// <summary>
/// Renders a TranscriptResult to Google Meet plain-text format.
/// Port of core/src/google_meet_renderer.rs.
/// </summary>
public static class GoogleMeetRenderer
{
    private const double MergeGapSecs = 1.5;
    private const double TurnBreakSecs = 3.0;

    public static string Render(TranscriptResult transcript, GoogleMeetOptions opts)
    {
        var turns = BuildTurns(transcript, opts);
        double durationSecs = TotalDuration(transcript);

        var sb = new StringBuilder();

        // Header
        sb.AppendLine("Google Meet Transcript");
        sb.AppendLine($"Session Date: {opts.SessionDate}");
        sb.AppendLine($"Duration: {FormatDuration(durationSecs)}");
        sb.AppendLine();

        // Turns
        foreach (var turn in turns)
        {
            sb.AppendLine($"[{FormatTimestamp(turn.StartSeconds)}]");
            sb.AppendLine($"{turn.SpeakerName}: {turn.Text}");
            sb.AppendLine();
        }

        // Session end + footer
        sb.AppendLine($"[Session ends {FormatTimestamp(durationSecs)}]");
        sb.AppendLine();
        sb.AppendLine("---");
        sb.AppendLine($"Total Duration: {FormatDuration(durationSecs)}");

        var speakers = UniqueSpeakers(transcript, opts);
        sb.AppendLine($"Speakers: {speakers.Count}");
        foreach (var (name, role) in speakers)
        {
            sb.AppendLine($"{name} ({role})");
        }

        return sb.ToString();
    }

    internal static string FormatTimestamp(double secs)
    {
        long total = (long)secs;
        long h = total / 3600;
        long m = (total % 3600) / 60;
        long s = total % 60;
        return $"{h:D2}:{m:D2}:{s:D2}";
    }

    internal static string FormatDuration(double secs)
    {
        long total = (long)secs;
        long h = total / 3600;
        long m = (total % 3600) / 60;
        long s = total % 60;
        return h > 0 ? $"{h}:{m:D2}:{s:D2}" : $"{m}:{s:D2}";
    }

    private static List<Turn> BuildTurns(TranscriptResult transcript, GoogleMeetOptions opts)
    {
        var turns = new List<Turn>();

        foreach (var seg in transcript.Segments)
        {
            string name = SpeakerName(seg.Speaker, opts);
            double gap = turns.Count > 0
                ? seg.StartSeconds - turns[^1].EndSeconds
                : double.MaxValue;

            bool sameSpeaker = turns.Count > 0 && turns[^1].SpeakerName == name;
            bool merge = sameSpeaker && gap <= MergeGapSecs && gap <= TurnBreakSecs;

            if (merge)
            {
                var current = turns[^1];
                current.Text += " " + seg.Text;
                current.EndSeconds = seg.EndSeconds;
            }
            else
            {
                turns.Add(new Turn
                {
                    StartSeconds = seg.StartSeconds,
                    EndSeconds = seg.EndSeconds,
                    SpeakerName = name,
                    Text = seg.Text,
                });
            }
        }

        return turns;
    }

    private static double TotalDuration(TranscriptResult transcript)
    {
        double max = 0;
        foreach (var seg in transcript.Segments)
        {
            if (seg.EndSeconds > max) max = seg.EndSeconds;
        }
        return max;
    }

    private static string SpeakerName(SpeakerLabel label, GoogleMeetOptions opts) => label switch
    {
        SpeakerLabel.Therapist => opts.TherapistName,
        SpeakerLabel.Client => opts.ClientName,
        _ => "Unknown",
    };

    private static List<(string Name, string Role)> UniqueSpeakers(TranscriptResult transcript, GoogleMeetOptions opts)
    {
        var seen = new List<SpeakerLabel>();
        foreach (var seg in transcript.Segments)
        {
            if (!seen.Contains(seg.Speaker))
                seen.Add(seg.Speaker);
        }

        return seen.Select(label =>
        {
            string name = SpeakerName(label, opts);
            string role = label switch
            {
                SpeakerLabel.Therapist => "Therapist",
                SpeakerLabel.Client => "Client",
                _ => "Unknown",
            };
            return (name, role);
        }).ToList();
    }

    private sealed class Turn
    {
        public double StartSeconds { get; set; }
        public double EndSeconds { get; set; }
        public string SpeakerName { get; set; } = "";
        public string Text { get; set; } = "";
    }
}

// Data types used by transcription services
public enum SpeakerLabel { Therapist, Client, Unknown }
public enum TranscriptionState { Idle, DownloadingModel, Preprocessing, Transcribing, Uploading, Complete, PendingUpload, Error }
public enum QualityPreset { Fast, Balanced, Accurate }

public sealed record TranscriptSegment(SpeakerLabel Speaker, double StartSeconds, double EndSeconds, string Text);
public sealed record TranscriptResult(string SessionId, TranscriptSegment[] Segments);
public sealed record TranscriptionProgress(TranscriptionState Phase, double Progress, string Message);
public sealed record GoogleMeetOptions(string SessionDate, string TherapistName, string ClientName);
