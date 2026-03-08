// session_pipeline.rs — 1:1 session transcription pipeline.
//
// Pipeline (1:1 mode, no diarization needed):
//   mic file   → preprocess → Whisper → all segments labeled THERAPIST
//   system file → preprocess → Whisper → all segments labeled CLIENT
//   merge both lists sorted by start time → TranscriptResult
//
// System audio file is optional: some recordings may have mic only (e.g. phone
// sessions where system audio capture was unavailable).

use crate::{
    audio_preprocessing, whisper_transcriber, PabloError, SessionMode, SpeakerLabel,
    TranscriptResult, TranscriptSegment, TranscriptionConfig,
};

pub async fn transcribe_session_1on1(
    session_id: String,
    mic_path: String,
    system_path: Option<String>,
    config: TranscriptionConfig,
) -> Result<TranscriptResult, PabloError> {
    // ── Mic pass: all segments → THERAPIST ───────────────────────────────────
    let mic_audio =
        audio_preprocessing::preprocess_pcm(mic_path, config.mic_channels, config.mic_sample_rate)
            .await?;

    let mic_raw =
        whisper_transcriber::transcribe_audio(config.model_path.clone(), mic_audio).await?;

    let mut segments: Vec<TranscriptSegment> = mic_raw
        .into_iter()
        .map(|s| TranscriptSegment {
            speaker: SpeakerLabel::Therapist,
            start_seconds: s.start_ms as f64 / 1000.0,
            end_seconds: s.end_ms as f64 / 1000.0,
            text: s.text,
        })
        .collect();

    // ── System audio pass: all segments → CLIENT ─────────────────────────────
    if let Some(sys_path) = system_path {
        let sys_audio = audio_preprocessing::preprocess_pcm(
            sys_path,
            config.system_channels,
            config.system_sample_rate,
        )
        .await?;

        let sys_raw = whisper_transcriber::transcribe_audio(config.model_path, sys_audio).await?;

        for s in sys_raw {
            segments.push(TranscriptSegment {
                speaker: SpeakerLabel::Client,
                start_seconds: s.start_ms as f64 / 1000.0,
                end_seconds: s.end_ms as f64 / 1000.0,
                text: s.text,
            });
        }
    }

    // ── Merge: sort by start time ─────────────────────────────────────────────
    segments.sort_by(|a, b| {
        a.start_seconds
            .partial_cmp(&b.start_seconds)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    Ok(TranscriptResult {
        session_id,
        session_mode: SessionMode::OneToOne,
        segments,
    })
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TranscriptionConfig;

    fn make_config() -> TranscriptionConfig {
        TranscriptionConfig {
            model_path: "nonexistent.bin".to_string(),
            mic_channels: 1,
            mic_sample_rate: 48000,
            system_channels: 2,
            system_sample_rate: 48000,
        }
    }

    #[test]
    fn merge_sorts_by_start_time() {
        // Build two interleaved segment lists and verify sort order
        let mut segments = vec![
            TranscriptSegment {
                speaker: SpeakerLabel::Therapist,
                start_seconds: 5.0,
                end_seconds: 7.0,
                text: "b".to_string(),
            },
            TranscriptSegment {
                speaker: SpeakerLabel::Client,
                start_seconds: 2.0,
                end_seconds: 4.0,
                text: "a".to_string(),
            },
            TranscriptSegment {
                speaker: SpeakerLabel::Therapist,
                start_seconds: 9.0,
                end_seconds: 11.0,
                text: "c".to_string(),
            },
        ];
        segments.sort_by(|a, b| {
            a.start_seconds
                .partial_cmp(&b.start_seconds)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        assert_eq!(segments[0].start_seconds, 2.0);
        assert_eq!(segments[1].start_seconds, 5.0);
        assert_eq!(segments[2].start_seconds, 9.0);
    }

    #[test]
    fn config_fields_accessible() {
        let c = make_config();
        assert_eq!(c.mic_channels, 1);
        assert_eq!(c.system_channels, 2);
        assert_eq!(c.mic_sample_rate, 48000);
        assert_eq!(c.system_sample_rate, 48000);
    }

    #[tokio::test]
    async fn mic_only_silent_audio_returns_empty_transcript() {
        use std::io::Write;
        let dir = std::env::temp_dir();
        let mic_path = dir.join("test_mic.pcm");

        // Write a tiny valid mono 48kHz PCM file (100 silent samples)
        let mut f = std::fs::File::create(&mic_path).unwrap();
        let samples: Vec<i16> = vec![0i16; 100];
        for s in &samples {
            f.write_all(&s.to_le_bytes()).unwrap();
        }

        let config = make_config();
        // Silent audio → VAD finds no speech → empty transcript (no model load needed)
        let result = transcribe_session_1on1(
            "test-session".to_string(),
            mic_path.to_str().unwrap().to_string(),
            None,
            config,
        )
        .await;

        std::fs::remove_file(&mic_path).ok();
        let transcript = result.unwrap();
        assert!(transcript.segments.is_empty());
    }
}
