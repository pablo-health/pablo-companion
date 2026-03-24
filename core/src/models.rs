// Domain types for the Pablo API client.
// All types have serde derives (JSON serialization) and UniFFI derives (FFI boundary).

use serde::{Deserialize, Serialize};

// ── Enums ────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionStatus {
    Scheduled,
    InProgress,
    RecordingComplete,
    Queued,
    Processing,
    PendingReview,
    Finalized,
    Cancelled,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VideoPlatform {
    Zoom,
    Teams,
    Meet,
    None,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionType {
    Individual,
    Couples,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionSource {
    Web,
    Companion,
    Calendar,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum QualityPreset {
    Fast,
    Balanced,
    Accurate,
}

// ── Structs ──────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PatientSummary {
    pub id: String,
    pub first_name: String,
    pub last_name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Session {
    pub id: String,
    pub patient_id: Option<String>,
    pub patient: Option<PatientSummary>,
    pub status: SessionStatus,
    pub scheduled_at: Option<String>,
    pub started_at: Option<String>,
    pub ended_at: Option<String>,
    pub duration_minutes: Option<u32>,
    pub video_link: Option<String>,
    pub video_platform: Option<VideoPlatform>,
    pub session_type: Option<SessionType>,
    pub source: Option<SessionSource>,
    pub notes: Option<String>,
    pub created_at: Option<String>,
    pub updated_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateSessionRequest {
    pub patient_id: String,
    pub scheduled_at: String,
    pub duration_minutes: Option<u32>,
    pub video_link: Option<String>,
    pub video_platform: Option<VideoPlatform>,
    pub session_type: Option<SessionType>,
    pub source: Option<SessionSource>,
    pub notes: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateSessionRequest {
    pub scheduled_at: Option<String>,
    pub video_link: Option<String>,
    pub video_platform: Option<VideoPlatform>,
    pub duration_minutes: Option<u32>,
    pub notes: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserPreferences {
    pub default_video_platform: VideoPlatform,
    pub default_session_type: SessionType,
    pub default_duration_minutes: u32,
    pub auto_transcribe: bool,
    pub quality_preset: QualityPreset,
    pub therapist_display_name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserProfile {
    pub id: String,
    pub email: String,
    pub first_name: String,
    pub last_name: String,
    pub role: String,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BaaStatus {
    pub baa_accepted: bool,
    pub accepted_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Patient {
    pub id: String,
    pub user_id: String,
    pub first_name: String,
    pub last_name: String,
    pub email: Option<String>,
    pub phone: Option<String>,
    pub status: String,
    pub date_of_birth: Option<String>,
    pub diagnosis: Option<String>,
    pub session_count: u32,
    pub last_session_date: Option<String>,
    pub next_session_date: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreatePatientRequest {
    pub first_name: String,
    pub last_name: String,
    pub email: Option<String>,
    pub phone: Option<String>,
    pub date_of_birth: Option<String>,
    pub diagnosis: Option<String>,
}

// ── Paginated response types ─────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionListResponse {
    pub data: Vec<Session>,
    #[serde(default)]
    pub total: u32,
    #[serde(default)]
    pub page: u32,
    #[serde(default)]
    pub page_size: u32,
    #[serde(default)]
    pub has_more: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PatientListResponse {
    pub data: Vec<Patient>,
    pub total: u32,
    pub page: u32,
    pub page_size: u32,
    #[serde(default)]
    pub has_more: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TranscriptUploadResponse {
    pub id: String,
    pub status: SessionStatus,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UploadResponse {
    pub id: String,
    pub status: String,
}

// ── Health / version types ────────────────────────────────────────────────

/// Result of a health check, including version compatibility info.
#[derive(Debug, Clone)]
pub struct HealthStatus {
    /// Server version string (e.g. "1.0.0"), empty if server didn't report it.
    pub server_version: String,
    /// True if this client version is below the server's minimum for our platform.
    pub client_update_required: bool,
    /// True if the server version is below this client's minimum server requirement.
    pub server_update_required: bool,
    /// The minimum client version the server requires (for our platform).
    pub min_client_version: String,
    /// The minimum server version this client requires.
    pub min_server_version: String,
}

// ── SOAP Entry types ────────────────────────────────────────────────────

/// Which phase of the EHR entry pipeline the backend is currently in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SoapEntryPhase {
    /// Job accepted, waiting for a Playwright slot.
    Queued,
    /// Navigating the EHR (login → dashboard → patient list).
    Navigating,
    /// Searching for the patient and verifying appointment match.
    MatchingPatient,
    /// Patient found — waiting for therapist to confirm before saving.
    AwaitingConfirmation,
    /// Therapist confirmed — entering SOAP note into the EHR fields.
    Entering,
    /// Note saved successfully in the EHR.
    Completed,
    /// Something went wrong (see `error` field for details).
    Failed,
    /// Therapist cancelled before save.
    Cancelled,
}

/// Request body to kick off SOAP note entry into an EHR.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SoapEntryRequest {
    /// Which EHR system (e.g. "simplepractice", "therapynotes", "janeapp").
    pub ehr_system: String,
    /// The Pablo SOAP note ID to enter.
    pub soap_note_id: String,
    /// Patient display name — used for verification in the EHR.
    pub patient_name: String,
    /// Expected appointment time (ISO 8601) — used for verification.
    pub appointment_time: String,
}

/// Current status of a SOAP entry job, returned by both the trigger and poll
/// endpoints. The native UI renders this as a progress indicator.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SoapEntryStatus {
    /// Backend-assigned job ID for this entry attempt.
    pub job_id: String,
    /// Current phase of the pipeline.
    pub phase: SoapEntryPhase,
    /// Human-readable status message for the therapist.
    pub message: String,
    /// Patient name as matched in the EHR (for confirmation display).
    pub patient_match: Option<String>,
    /// Appointment time as matched in the EHR (for confirmation display).
    pub appointment_match: Option<String>,
    /// Where in the EHR the note will be saved (for confirmation display).
    pub ehr_target_field: Option<String>,
    /// Error details if phase is `Failed`.
    pub error: Option<String>,
}

/// Preview data shown to the therapist before they confirm the entry.
/// Extracted from `SoapEntryStatus` when phase is `awaiting_confirmation`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SoapEntryConfirmation {
    pub patient_match: String,
    pub appointment_match: String,
    pub ehr_target_field: String,
    /// Optional preview of the SOAP note content that will be entered.
    pub soap_preview: Option<String>,
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_status_serde_roundtrip() {
        let status = SessionStatus::InProgress;
        let json = serde_json::to_string(&status).unwrap();
        assert_eq!(json, "\"in_progress\"");
        let parsed: SessionStatus = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, status);
    }

    #[test]
    fn video_platform_serde_roundtrip() {
        let platform = VideoPlatform::Zoom;
        let json = serde_json::to_string(&platform).unwrap();
        assert_eq!(json, "\"zoom\"");
        let parsed: VideoPlatform = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, platform);
    }

    #[test]
    fn session_json_deserialization() {
        let json = r#"{
            "id": "sess-001",
            "patient_id": "pat-001",
            "patient": null,
            "status": "scheduled",
            "scheduled_at": "2026-03-07T10:00:00Z",
            "started_at": null,
            "ended_at": null,
            "duration_minutes": 50,
            "video_link": null,
            "video_platform": null,
            "session_type": "individual",
            "source": "companion",
            "notes": null,
            "created_at": "2026-03-06T12:00:00Z",
            "updated_at": "2026-03-06T12:00:00Z"
        }"#;
        let session: Session = serde_json::from_str(json).unwrap();
        assert_eq!(session.id, "sess-001");
        assert_eq!(session.status, SessionStatus::Scheduled);
        assert_eq!(session.session_type, Some(SessionType::Individual));
        assert_eq!(session.source, Some(SessionSource::Companion));
        assert_eq!(session.duration_minutes, Some(50));
    }

    #[test]
    fn user_preferences_defaults_serde() {
        let prefs = UserPreferences {
            default_video_platform: VideoPlatform::Zoom,
            default_session_type: SessionType::Individual,
            default_duration_minutes: 50,
            auto_transcribe: true,
            quality_preset: QualityPreset::Balanced,
            therapist_display_name: "Dr. Smith".to_string(),
        };
        let json = serde_json::to_string(&prefs).unwrap();
        let parsed: UserPreferences = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.default_video_platform, VideoPlatform::Zoom);
        assert_eq!(parsed.default_duration_minutes, 50);
        assert!(parsed.auto_transcribe);
    }
}
