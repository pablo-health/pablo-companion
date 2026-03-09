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
    pub patient_id: String,
    pub patient: Option<PatientSummary>,
    pub status: SessionStatus,
    pub scheduled_at: Option<String>,
    pub started_at: Option<String>,
    pub ended_at: Option<String>,
    pub duration_minutes: u32,
    pub video_link: Option<String>,
    pub video_platform: Option<VideoPlatform>,
    pub session_type: SessionType,
    pub source: SessionSource,
    pub notes: Option<String>,
    pub created_at: String,
    pub updated_at: String,
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
        assert_eq!(session.session_type, SessionType::Individual);
        assert_eq!(session.source, SessionSource::Companion);
        assert_eq!(session.duration_minutes, 50);
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
