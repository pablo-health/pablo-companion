// pablo-core: shared business logic for Pablo Companion (macOS + Windows).
//
// FFI boundary rule: simple async functions, plain value types.
// No complex generics, no closures, no shared mutable state across the boundary.

uniffi::include_scaffolding!("pablo_core");

// ── Public types exposed via UniFFI ──────────────────────────────────────────

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
