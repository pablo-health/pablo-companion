// whisper_transcriber.rs — Whisper-based ASR via whisper-rs.
//
// Exposes a single async function `transcribe_audio` that loads a GGML model
// and transcribes 16 kHz mono f32 PCM audio.  Model loading and inference are
// dispatched to a blocking thread so the tokio runtime stays free.
//
// Fixed inference params (per design doc §4):
//   language      = en
//   token_timestamps = true   (required for diarization alignment downstream)
//   beam_size     = 5

use crate::PabloError;
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

// ── Public types ──────────────────────────────────────────────────────────────

/// A single raw ASR segment as returned by Whisper.
/// Timestamps are in milliseconds (Whisper reports centiseconds; we convert).
#[derive(Debug, Clone)]
pub struct RawSegment {
    pub start_ms: i64,
    pub end_ms: i64,
    pub text: String,
}

// ── Public API ────────────────────────────────────────────────────────────────

/// Load the GGML model at `model_path` and transcribe `audio` (16 kHz mono f32).
///
/// Returns one `RawSegment` per Whisper sentence segment, ordered by start time.
/// Empty or silent audio returns an empty Vec.
pub async fn transcribe_audio(
    model_path: String,
    audio: Vec<f32>,
) -> Result<Vec<RawSegment>, PabloError> {
    tokio::task::spawn_blocking(move || run_transcription(&model_path, &audio))
        .await
        .map_err(|e| PabloError::WhisperTranscribe {
            message: format!("transcription thread panicked: {e}"),
        })?
}

// ── Private helpers ───────────────────────────────────────────────────────────

fn run_transcription(model_path: &str, audio: &[f32]) -> Result<Vec<RawSegment>, PabloError> {
    let ctx = WhisperContext::new_with_params(model_path, WhisperContextParameters::default())
        .map_err(|e| PabloError::WhisperInit {
            message: format!("failed to load model '{model_path}': {e}"),
        })?;

    let mut state = ctx.create_state().map_err(|e| PabloError::WhisperInit {
        message: format!("failed to create whisper state: {e}"),
    })?;

    let mut params = FullParams::new(SamplingStrategy::BeamSearch {
        beam_size: 5,
        patience: -1.0,
    });
    params.set_language(Some("en"));
    params.set_token_timestamps(true);

    state
        .full(params, audio)
        .map_err(|e| PabloError::WhisperTranscribe {
            message: format!("whisper inference failed: {e}"),
        })?;

    let mut segments = Vec::new();
    for seg in state.as_iter() {
        // Whisper timestamps are centiseconds (100ths of a second) → convert to ms
        let start_ms: i64 = seg.start_timestamp() * 10;
        let end_ms: i64 = seg.end_timestamp() * 10;
        let text = seg
            .to_str_lossy()
            .map_err(|e| PabloError::WhisperTranscribe {
                message: format!("invalid UTF-8 in segment: {e}"),
            })?
            .trim()
            .to_string();
        segments.push(RawSegment {
            start_ms,
            end_ms,
            text,
        });
    }

    Ok(segments)
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raw_segment_fields() {
        let seg = RawSegment {
            start_ms: 0,
            end_ms: 2500,
            text: "Hello world".to_string(),
        };
        assert_eq!(seg.start_ms, 0);
        assert_eq!(seg.end_ms, 2500);
        assert_eq!(seg.text, "Hello world");
    }

    #[test]
    fn raw_segment_clone() {
        let seg = RawSegment {
            start_ms: 100,
            end_ms: 500,
            text: "Test".to_string(),
        };
        let cloned = seg.clone();
        assert_eq!(cloned.start_ms, seg.start_ms);
        assert_eq!(cloned.text, seg.text);
    }
}
