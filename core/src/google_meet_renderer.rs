// google_meet_renderer.rs — Renders a TranscriptResult to Google Meet plain-text format.
//
// The downstream Pablo SOAP note pipeline expects this exact format.
// Format spec: docs/audio-transcription-design.md §6 Google Meet Format Export.
//
// Turn segmentation rules:
//   - New turn on speaker change
//   - New turn on pause > 3 s (even same speaker)
//   - Merge adjacent same-speaker segments with gap ≤ 1.5 s (no turn break)

use crate::{GoogleMeetOptions, SpeakerLabel, TranscriptResult};

const MERGE_GAP_SECS: f64 = 1.5;
const TURN_BREAK_SECS: f64 = 3.0;

// ── Public API ────────────────────────────────────────────────────────────────

pub fn render_google_meet(transcript: &TranscriptResult, opts: &GoogleMeetOptions) -> String {
    let turns = build_turns(transcript, opts);
    let duration_secs = total_duration(transcript);

    let mut out = String::new();

    // Header
    out.push_str("Google Meet Transcript\n");
    out.push_str(&format!("Session Date: {}\n", opts.session_date));
    out.push_str(&format!("Duration: {}\n", format_duration(duration_secs)));
    out.push('\n');

    // Turns
    for turn in &turns {
        out.push_str(&format!("[{}]\n", format_timestamp(turn.start_seconds)));
        out.push_str(&format!("{}: {}\n", turn.speaker_name, turn.text));
        out.push('\n');
    }

    // Session end + footer
    out.push_str(&format!(
        "[Session ends {}]\n",
        format_timestamp(duration_secs)
    ));
    out.push('\n');
    out.push_str("---\n");
    out.push_str(&format!(
        "Total Duration: {}\n",
        format_duration(duration_secs)
    ));

    let speakers = unique_speakers(transcript, opts);
    out.push_str(&format!("Speakers: {}\n", speakers.len()));
    for (name, role) in &speakers {
        out.push_str(&format!("{name} ({role})\n"));
    }

    out
}

// ── Turn building ─────────────────────────────────────────────────────────────

struct Turn {
    start_seconds: f64,
    end_seconds: f64,
    speaker_name: String,
    text: String,
}

fn build_turns(transcript: &TranscriptResult, opts: &GoogleMeetOptions) -> Vec<Turn> {
    let mut turns: Vec<Turn> = Vec::new();

    for seg in &transcript.segments {
        let name = speaker_name(&seg.speaker, opts);
        let gap = turns
            .last()
            .map(|t: &Turn| seg.start_seconds - t.end_seconds)
            .unwrap_or(f64::MAX);

        let same_speaker = turns.last().is_some_and(|t| t.speaker_name == name);
        let merge = same_speaker && gap <= MERGE_GAP_SECS && gap <= TURN_BREAK_SECS;

        if merge {
            if let Some(current) = turns.last_mut() {
                current.text.push(' ');
                current.text.push_str(&seg.text);
                current.end_seconds = seg.end_seconds;
            }
        } else {
            turns.push(Turn {
                start_seconds: seg.start_seconds,
                end_seconds: seg.end_seconds,
                speaker_name: name,
                text: seg.text.clone(),
            });
        }
    }

    turns
}

// ── Formatting helpers ────────────────────────────────────────────────────────

/// Seconds → `HH:MM:SS` (always 2-digit hours, as required for body timestamps).
fn format_timestamp(secs: f64) -> String {
    let total = secs as u64;
    let h = total / 3600;
    let m = (total % 3600) / 60;
    let s = total % 60;
    format!("{h:02}:{m:02}:{s:02}")
}

/// Seconds → duration string: `M:SS` (< 1 h) or `H:MM:SS` (≥ 1 h).
fn format_duration(secs: f64) -> String {
    let total = secs as u64;
    let h = total / 3600;
    let m = (total % 3600) / 60;
    let s = total % 60;
    if h > 0 {
        format!("{h}:{m:02}:{s:02}")
    } else {
        format!("{m}:{s:02}")
    }
}

fn total_duration(transcript: &TranscriptResult) -> f64 {
    transcript
        .segments
        .iter()
        .map(|s| s.end_seconds)
        .fold(0.0_f64, f64::max)
}

fn speaker_name(label: &SpeakerLabel, opts: &GoogleMeetOptions) -> String {
    match label {
        SpeakerLabel::Therapist => opts.therapist_name.clone(),
        SpeakerLabel::Client => opts.client_name.clone(),
        SpeakerLabel::ClientA => opts.client_a_name.clone(),
        SpeakerLabel::ClientB => opts.client_b_name.clone(),
        SpeakerLabel::Unknown => "Unknown".to_string(),
    }
}

fn unique_speakers(
    transcript: &TranscriptResult,
    opts: &GoogleMeetOptions,
) -> Vec<(String, String)> {
    let mut seen: Vec<SpeakerLabel> = Vec::new();
    for seg in &transcript.segments {
        if !seen.contains(&seg.speaker) {
            seen.push(seg.speaker.clone());
        }
    }
    seen.into_iter()
        .map(|label| {
            let name = speaker_name(&label, opts);
            let role = match label {
                SpeakerLabel::Therapist => "Therapist".to_string(),
                SpeakerLabel::Client | SpeakerLabel::ClientA | SpeakerLabel::ClientB => {
                    "Client".to_string()
                }
                SpeakerLabel::Unknown => "Unknown".to_string(),
            };
            (name, role)
        })
        .collect()
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{SessionMode, TranscriptSegment};

    fn opts() -> GoogleMeetOptions {
        GoogleMeetOptions {
            session_date: "April 3, 2024".to_string(),
            therapist_name: "Dr. Lee".to_string(),
            client_name: "Alex".to_string(),
            client_a_name: "Alex".to_string(),
            client_b_name: "Jordan".to_string(),
        }
    }

    fn make_transcript(segments: Vec<TranscriptSegment>) -> TranscriptResult {
        TranscriptResult {
            session_id: "test-session".to_string(),
            session_mode: SessionMode::OneToOne,
            segments,
        }
    }

    #[test]
    fn format_timestamp_zero() {
        assert_eq!(format_timestamp(0.0), "00:00:00");
    }

    #[test]
    fn format_timestamp_1hr() {
        assert_eq!(format_timestamp(3661.0), "01:01:01");
    }

    #[test]
    fn format_duration_under_1hr() {
        assert_eq!(format_duration(314.0), "5:14");
    }

    #[test]
    fn format_duration_over_1hr() {
        assert_eq!(format_duration(3720.0), "1:02:00");
    }

    #[test]
    fn empty_transcript_renders_header() {
        let t = make_transcript(vec![]);
        let out = render_google_meet(&t, &opts());
        assert!(out.starts_with("Google Meet Transcript\n"));
        assert!(out.contains("Session Date: April 3, 2024"));
        assert!(out.contains("Duration: 0:00"));
        assert!(out.contains("Speakers: 0"));
    }

    #[test]
    fn single_turn_renders_correctly() {
        let t = make_transcript(vec![TranscriptSegment {
            speaker: SpeakerLabel::Therapist,
            start_seconds: 8.0,
            end_seconds: 12.0,
            text: "Good afternoon.".to_string(),
        }]);
        let out = render_google_meet(&t, &opts());
        assert!(out.contains("[00:00:08]"));
        assert!(out.contains("Dr. Lee: Good afternoon."));
        assert!(out.contains("[Session ends 00:00:12]"));
        assert!(out.contains("Speakers: 1"));
        assert!(out.contains("Dr. Lee (Therapist)"));
    }

    #[test]
    fn adjacent_same_speaker_within_merge_gap_merges() {
        let t = make_transcript(vec![
            TranscriptSegment {
                speaker: SpeakerLabel::Therapist,
                start_seconds: 0.0,
                end_seconds: 2.0,
                text: "Hello".to_string(),
            },
            TranscriptSegment {
                speaker: SpeakerLabel::Therapist,
                start_seconds: 3.0, // gap = 1.0 s ≤ 1.5 s → merge
                end_seconds: 5.0,
                text: "world.".to_string(),
            },
        ]);
        let out = render_google_meet(&t, &opts());
        assert!(out.contains("Dr. Lee: Hello world."));
        assert_eq!(out.matches("[00:00:00]").count(), 1);
    }

    #[test]
    fn pause_over_3s_same_speaker_creates_new_turn() {
        let t = make_transcript(vec![
            TranscriptSegment {
                speaker: SpeakerLabel::Therapist,
                start_seconds: 0.0,
                end_seconds: 2.0,
                text: "First.".to_string(),
            },
            TranscriptSegment {
                speaker: SpeakerLabel::Therapist,
                start_seconds: 6.0, // gap = 4.0 s > 3.0 s → new turn
                end_seconds: 8.0,
                text: "Second.".to_string(),
            },
        ]);
        let out = render_google_meet(&t, &opts());
        assert!(out.contains("[00:00:00]"));
        assert!(out.contains("[00:00:06]"));
    }

    #[test]
    fn speaker_change_creates_new_turn() {
        let t = make_transcript(vec![
            TranscriptSegment {
                speaker: SpeakerLabel::Therapist,
                start_seconds: 0.0,
                end_seconds: 3.0,
                text: "How are you?".to_string(),
            },
            TranscriptSegment {
                speaker: SpeakerLabel::Client,
                start_seconds: 4.0,
                end_seconds: 7.0,
                text: "I'm okay.".to_string(),
            },
        ]);
        let out = render_google_meet(&t, &opts());
        assert!(out.contains("Dr. Lee: How are you?"));
        assert!(out.contains("Alex: I'm okay."));
        assert!(out.contains("Speakers: 2"));
    }

    #[test]
    fn two_digit_hours_in_body_timestamps() {
        let t = make_transcript(vec![TranscriptSegment {
            speaker: SpeakerLabel::Client,
            start_seconds: 4000.0, // 1h 6m 40s
            end_seconds: 4005.0,
            text: "Late in session.".to_string(),
        }]);
        let out = render_google_meet(&t, &opts());
        assert!(out.contains("[01:06:40]"));
    }
}
