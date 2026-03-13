// pablo-core: shared business logic for Pablo Companion (macOS + Windows).
//
// FFI boundary rule: simple async functions, plain value types.
// No complex generics, no closures, no shared mutable state across the boundary.

use async_compat::Compat;

uniffi::include_scaffolding!("pablo_core");

pub mod api_client;
pub mod audio_preprocessing;
pub mod google_meet_renderer;
pub mod models;
pub mod session_pipeline;
pub mod whisper_transcriber;

pub use api_client::*;
pub use models::*;

pub use whisper_transcriber::RawSegment;

// ── Error type ───────────────────────────────────────────────────────────────

/// Unified error type for all pablo-core operations, exposed via UniFFI.
#[derive(Debug, thiserror::Error)]
pub enum PabloError {
    #[error("Audio preprocessing error: {message}")]
    AudioPreprocessing { message: String },
    #[error("Whisper model init error: {message}")]
    WhisperInit { message: String },
    #[error("Whisper transcription error: {message}")]
    WhisperTranscribe { message: String },
    #[error("API error (HTTP {status_code}): {message}")]
    ApiClient { status_code: u16, message: String },
    #[error("JSON parse error: {message}")]
    JsonParse { message: String },
    #[error("Unauthenticated — login required")]
    Unauthenticated,
    #[error("Forbidden — insufficient permissions")]
    Forbidden,
    #[error("Not found: {resource}")]
    NotFound { resource: String },
    #[error("Conflict: {message}")]
    ConflictState { message: String },
}

// ── Public types exposed via UniFFI ──────────────────────────────────────────

/// Options for rendering a transcript to Google Meet format.
#[derive(Debug, Clone)]
pub struct GoogleMeetOptions {
    /// Session date string, e.g. "April 3, 2024" (formatted by the caller).
    pub session_date: String,
    /// Display name for the therapist speaker.
    pub therapist_name: String,
    /// Display name for the client speaker (1:1 mode).
    pub client_name: String,
    /// Display name for client A (couples mode).
    pub client_a_name: String,
    /// Display name for client B (couples mode).
    pub client_b_name: String,
}

/// Configuration for a local transcription run.
#[derive(Debug, Clone)]
pub struct TranscriptionConfig {
    /// Path to the GGML Whisper model file.
    pub model_path: String,
    /// Number of channels in the mic recording (always 1 — mono).
    pub mic_channels: u8,
    /// Sample rate of the mic recording (48000 built-in, 16000 Bluetooth HFP).
    pub mic_sample_rate: u32,
    /// Number of channels in the system audio recording (always 2 — stereo).
    pub system_channels: u8,
    /// Sample rate of the system audio recording.
    pub system_sample_rate: u32,
    /// When true, mic audio is labeled Client and system audio is labeled Therapist.
    /// Default false: mic = Therapist, system = Client.
    pub swap_speakers: bool,
}

/// Who spoke a given transcript segment.
#[derive(Debug, Clone, PartialEq)]
pub enum SpeakerLabel {
    Therapist,
    Client,
    ClientA,
    ClientB,
    Unknown,
}

/// Whether the session is a 1:1 (therapist + one client) or couples session
/// (therapist + two clients). Controls which pipeline stages run.
#[derive(Debug, Clone, PartialEq)]
pub enum SessionMode {
    OneToOne,
    Couples,
}

/// A single speaker turn in the transcript.
#[derive(Debug, Clone)]
pub struct TranscriptSegment {
    pub speaker: SpeakerLabel,
    pub start_seconds: f64,
    pub end_seconds: f64,
    pub text: String,
}

/// The complete transcript for one session.
#[derive(Debug, Clone)]
pub struct TranscriptResult {
    pub session_id: String,
    pub session_mode: SessionMode,
    pub segments: Vec<TranscriptSegment>,
}

// ── Namespace functions ───────────────────────────────────────────────────────

/// Returns the pablo-core crate version. Used by Swift to confirm FFI is wired.
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Audio preprocessing: raw PCM (signed 16-bit LE) -> mono f32 at 16 kHz.
/// `sample_rate` is the actual input rate (e.g. 48000 built-in, 16000 Bluetooth HFP).
pub async fn preprocess_pcm(
    path: String,
    channels: u8,
    sample_rate: u32,
) -> Result<Vec<f32>, PabloError> {
    Compat::new(audio_preprocessing::preprocess_pcm(
        path,
        channels,
        sample_rate,
    ))
    .await
}

/// Render a TranscriptResult to Google Meet plain-text format.
/// The resulting string is what the Pablo SOAP note pipeline expects.
pub fn render_google_meet(transcript: TranscriptResult, opts: GoogleMeetOptions) -> String {
    google_meet_renderer::render_google_meet(&transcript, &opts)
}

/// 1:1 session transcription pipeline.
/// Preprocesses and transcribes mic and (optionally) system audio files,
/// labels segments THERAPIST / CLIENT, merges by start time, returns TranscriptResult.
pub async fn transcribe_session_1on1(
    session_id: String,
    mic_path: String,
    system_path: Option<String>,
    config: TranscriptionConfig,
) -> Result<TranscriptResult, PabloError> {
    Compat::new(session_pipeline::transcribe_session_1on1(
        session_id,
        mic_path,
        system_path,
        config,
    ))
    .await
}

/// Transcribe 16 kHz mono f32 audio using the GGML Whisper model at `model_path`.
/// Returns one `RawSegment` per sentence segment, ordered by start time.
/// Fixed params: language=en, token_timestamps=true, beam_size=5.
pub async fn transcribe_audio(
    model_path: String,
    audio: Vec<f32>,
) -> Result<Vec<RawSegment>, PabloError> {
    Compat::new(whisper_transcriber::transcribe_audio(model_path, audio)).await
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn core_version_is_semver() {
        let v = core_version();
        // Verify it looks like a semver string (at least "major.minor.patch")
        let parts: Vec<&str> = v.split('.').collect();
        assert!(parts.len() >= 3, "expected semver, got: {v}");
    }

    #[test]
    fn transcript_result_roundtrip() {
        let result = TranscriptResult {
            session_id: "session-123".to_string(),
            session_mode: SessionMode::OneToOne,
            segments: vec![
                TranscriptSegment {
                    speaker: SpeakerLabel::Therapist,
                    start_seconds: 0.0,
                    end_seconds: 2.5,
                    text: "How are you feeling today?".to_string(),
                },
                TranscriptSegment {
                    speaker: SpeakerLabel::Client,
                    start_seconds: 3.1,
                    end_seconds: 6.0,
                    text: "Better than last week.".to_string(),
                },
            ],
        };

        assert_eq!(result.segments.len(), 2);
        assert_eq!(result.segments[0].speaker, SpeakerLabel::Therapist);
        assert_eq!(result.segments[1].speaker, SpeakerLabel::Client);
        assert_eq!(result.session_mode, SessionMode::OneToOne);
    }
}
