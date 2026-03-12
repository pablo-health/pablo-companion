// whisper_transcriber.rs — Whisper-based ASR via whisper-rs.
//
// Pipeline: audio → VAD split → transcribe each speech chunk → reassemble.
//
// The audio is scanned for speech regions using RMS energy detection. Each
// contiguous speech region is fed to Whisper independently, so the model never
// sees long silence gaps and can't bridge across them. Segment timestamps are
// offset back to the original file timeline.
//
// Fixed inference params (per design doc §4):
//   language      = en
//   token_timestamps = true   (required for diarization alignment downstream)
//   beam_size     = 5

use crate::PabloError;
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

/// Sample rate of audio fed to Whisper (always 16 kHz after preprocessing).
const WHISPER_SAMPLE_RATE: usize = 16000;

/// RMS energy below this threshold = silence.
const SILENCE_RMS_THRESHOLD: f32 = 0.01;

/// Window size in samples for VAD scanning (20ms at 16 kHz = 320 samples).
const VAD_WINDOW_SAMPLES: usize = (WHISPER_SAMPLE_RATE * 20) / 1000;

/// Minimum silence gap in ms to split speech regions. Gaps shorter than this
/// are treated as part of the same utterance (natural pauses within a sentence).
const MIN_SILENCE_GAP_MS: usize = 500;

/// Minimum speech region duration in samples. Whisper requires at least 100ms
/// of audio; regions shorter than this are discarded to avoid the
/// "input is too short" warning.
const MIN_REGION_SAMPLES: usize = WHISPER_SAMPLE_RATE / 10; // 1600 samples = 100ms

// ── Public types ──────────────────────────────────────────────────────────────

/// A single raw ASR segment as returned by Whisper.
/// Timestamps are in milliseconds.
#[derive(Debug, Clone)]
pub struct RawSegment {
    pub start_ms: i64,
    pub end_ms: i64,
    pub text: String,
}

/// A contiguous region of speech detected by VAD.
#[derive(Debug, Clone)]
struct SpeechRegion {
    start_sample: usize,
    end_sample: usize,
}

impl SpeechRegion {
    fn start_ms(&self) -> i64 {
        (self.start_sample * 1000 / WHISPER_SAMPLE_RATE) as i64
    }

    fn samples<'a>(&self, audio: &'a [f32]) -> &'a [f32] {
        &audio[self.start_sample..self.end_sample.min(audio.len())]
    }
}

// ── Public API ────────────────────────────────────────────────────────────────

/// Load the GGML model at `model_path` and transcribe `audio` (16 kHz mono f32).
///
/// The audio is split at silence boundaries before transcription so that
/// Whisper processes each speech region independently. This prevents the model
/// from bridging across silence gaps (which causes timestamp errors and
/// hallucinations).
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
    // 1. Find speech regions via VAD
    let regions = detect_speech_regions(audio);
    if regions.is_empty() {
        return Ok(Vec::new());
    }

    // 2. Load model once, reuse for all chunks
    let ctx = WhisperContext::new_with_params(model_path, WhisperContextParameters::default())
        .map_err(|e| PabloError::WhisperInit {
            message: format!("failed to load model '{model_path}': {e}"),
        })?;

    // 3. Transcribe each speech region independently
    let mut all_segments = Vec::new();
    for region in &regions {
        let chunk = region.samples(audio);
        let offset_ms = region.start_ms();

        let chunk_segments = transcribe_chunk(&ctx, chunk, offset_ms)?;
        all_segments.extend(chunk_segments);
    }

    Ok(all_segments)
}

/// Transcribe a single speech chunk using an already-loaded model context.
/// Whisper timestamps are relative to the chunk start; `offset_ms` shifts
/// them back to the original file timeline.
fn transcribe_chunk(
    ctx: &WhisperContext,
    audio: &[f32],
    offset_ms: i64,
) -> Result<Vec<RawSegment>, PabloError> {
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
        let start_ms = seg.start_timestamp() * 10 + offset_ms;
        let end_ms = seg.end_timestamp() * 10 + offset_ms;

        let text = clean_text(
            &seg.to_str_lossy()
                .map_err(|e| PabloError::WhisperTranscribe {
                    message: format!("invalid UTF-8 in segment: {e}"),
                })?,
        );

        if text.is_empty() {
            continue;
        }

        segments.push(RawSegment {
            start_ms,
            end_ms,
            text,
        });
    }

    Ok(segments)
}

/// Scan audio in small windows and return contiguous speech regions.
///
/// A speech region starts when RMS rises above the threshold and ends after
/// `MIN_SILENCE_GAP_MS` of consecutive silence. Short silence gaps within
/// speech (natural pauses) are absorbed into the region.
fn detect_speech_regions(audio: &[f32]) -> Vec<SpeechRegion> {
    let min_silence_windows =
        (MIN_SILENCE_GAP_MS * WHISPER_SAMPLE_RATE) / (1000 * VAD_WINDOW_SAMPLES);
    let mut regions = Vec::new();
    let mut in_speech = false;
    let mut region_start = 0;
    let mut silence_count = 0;

    let mut pos = 0;
    while pos + VAD_WINDOW_SAMPLES <= audio.len() {
        let window = &audio[pos..pos + VAD_WINDOW_SAMPLES];
        let sum_sq: f64 = window.iter().map(|&s| (s as f64) * (s as f64)).sum();
        let rms = (sum_sq / window.len() as f64).sqrt() as f32;
        let is_speech = rms >= SILENCE_RMS_THRESHOLD;

        if is_speech {
            if !in_speech {
                region_start = pos;
                in_speech = true;
            }
            silence_count = 0;
        } else if in_speech {
            silence_count += 1;
            if silence_count >= min_silence_windows {
                // End of speech region — rewind past the trailing silence
                let region_end = pos - (silence_count - 1) * VAD_WINDOW_SAMPLES;
                regions.push(SpeechRegion {
                    start_sample: region_start,
                    end_sample: region_end,
                });
                in_speech = false;
                silence_count = 0;
            }
        }

        pos += VAD_WINDOW_SAMPLES;
    }

    // Close any open region at end of audio
    if in_speech {
        regions.push(SpeechRegion {
            start_sample: region_start,
            end_sample: audio.len(),
        });
    }

    // Drop regions shorter than Whisper's minimum input (100ms)
    regions.retain(|r| r.end_sample - r.start_sample >= MIN_REGION_SAMPLES);

    regions
}

/// Strip artifacts that Whisper sometimes adds to the text:
/// - Leading/trailing quotation marks (common with clear/scripted speech)
/// - Leading/trailing whitespace
fn clean_text(raw: &str) -> String {
    let trimmed = raw.trim();
    let stripped = trimmed
        .strip_prefix('"')
        .unwrap_or(trimmed)
        .strip_suffix('"')
        .unwrap_or(trimmed)
        .trim();
    stripped.to_string()
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

    // ── clean_text tests ─────────────────────────────────────────────────────

    #[test]
    fn clean_text_strips_quotes() {
        assert_eq!(clean_text("\"Hello world.\""), "Hello world.");
        assert_eq!(clean_text("  \"Hello\"  "), "Hello");
    }

    #[test]
    fn clean_text_preserves_inner_quotes() {
        assert_eq!(
            clean_text("She said \"hello\" to me."),
            "She said \"hello\" to me."
        );
    }

    #[test]
    fn clean_text_no_quotes_unchanged() {
        assert_eq!(clean_text("Hello world."), "Hello world.");
    }

    #[test]
    fn clean_text_empty_after_strip() {
        assert_eq!(clean_text("  "), "");
        assert_eq!(clean_text("\"\""), "");
    }

    // ── VAD / speech region tests ────────────────────────────────────────────

    fn make_sine(num_samples: usize, amplitude: f32) -> Vec<f32> {
        (0..num_samples)
            .map(|i| (i as f32 / 16000.0 * std::f32::consts::TAU * 440.0).sin() * amplitude)
            .collect()
    }

    #[test]
    fn silence_produces_no_regions() {
        let silence = vec![0.0f32; 48000]; // 3 seconds
        let regions = detect_speech_regions(&silence);
        assert!(regions.is_empty());
    }

    #[test]
    fn continuous_speech_single_region() {
        let speech = make_sine(48000, 0.1); // 3 seconds of speech
        let regions = detect_speech_regions(&speech);
        assert_eq!(regions.len(), 1);
        assert_eq!(regions[0].start_sample, 0);
    }

    #[test]
    fn two_utterances_with_long_gap() {
        // 1s speech, 1s silence, 1s speech
        let mut audio = make_sine(16000, 0.1);
        audio.extend(vec![0.0f32; 16000]);
        audio.extend(make_sine(16000, 0.1));

        let regions = detect_speech_regions(&audio);
        assert_eq!(regions.len(), 2, "expected 2 regions, got {:?}", regions);

        // First region should be ~0-1s
        assert_eq!(regions[0].start_sample, 0);
        // Second region should start at ~2s
        let second_start_ms = regions[1].start_ms();
        assert!(
            second_start_ms >= 1800 && second_start_ms <= 2200,
            "second region started at {second_start_ms}ms, expected ~2000ms"
        );
    }

    #[test]
    fn short_pause_within_speech_not_split() {
        // 1s speech, 200ms pause (< 500ms threshold), 1s speech → single region
        let mut audio = make_sine(16000, 0.1);
        audio.extend(vec![0.0f32; 3200]); // 200ms
        audio.extend(make_sine(16000, 0.1));

        let regions = detect_speech_regions(&audio);
        assert_eq!(
            regions.len(),
            1,
            "short pause should not split: {:?}",
            regions
        );
    }

    #[test]
    fn speech_with_leading_silence() {
        // 2s silence, then 1s speech
        let mut audio = vec![0.0f32; 32000];
        audio.extend(make_sine(16000, 0.1));

        let regions = detect_speech_regions(&audio);
        assert_eq!(regions.len(), 1);
        let start_ms = regions[0].start_ms();
        assert!(
            start_ms >= 1980 && start_ms <= 2020,
            "region started at {start_ms}ms, expected ~2000ms"
        );
    }

    #[test]
    fn three_utterances() {
        // Simulates therapist file: speech, silence, speech, silence, speech
        let mut audio = Vec::new();
        for i in 0..3 {
            if i > 0 {
                audio.extend(vec![0.0f32; 16000]); // 1s silence gap
            }
            audio.extend(make_sine(16000, 0.1)); // 1s speech
        }

        let regions = detect_speech_regions(&audio);
        assert_eq!(regions.len(), 3, "expected 3 regions, got {:?}", regions);
    }
}
