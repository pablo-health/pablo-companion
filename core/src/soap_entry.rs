// SOAP note EHR entry orchestration.
//
// The companion app triggers EHR entry via the Pablo backend API. The backend
// runs Playwright headless + cached routes + LLM fallback to navigate the
// therapist's EHR and enter the SOAP note. The companion's job is thin:
//   1. Trigger: POST /sessions/{id}/enter-soap
//   2. Poll:    GET  /sessions/{id}/soap-entry-status
//   3. Confirm: POST /sessions/{id}/soap-entry-confirm
//   4. Cancel:  POST /sessions/{id}/soap-entry-cancel
//
// All intelligence lives on the backend. The Rust core just manages the
// request lifecycle and exposes status to the native UI layer.

use async_compat::Compat;
use secrecy::SecretString;

use crate::api_client::{handle_error_response, ApiClient};
use crate::models::{SoapEntryRequest, SoapEntryStatus};
use crate::PabloError;

// ── Public endpoint functions (exposed via UniFFI) ──────────────────────────

/// Start SOAP note entry into the therapist's EHR.
///
/// The backend begins a Playwright session, navigates to the correct patient
/// in the EHR, and prepares to enter the SOAP note. Returns the initial status
/// (typically `navigating`).
pub async fn start_soap_entry(
    base_url: String,
    token: String,
    session_id: String,
    request: SoapEntryRequest,
) -> Result<SoapEntryStatus, PabloError> {
    Compat::new(async move {
        let client = ApiClient::new(base_url);
        let token = SecretString::from(token);

        let response = client
            .post(&format!("/api/sessions/{session_id}/enter-soap"), &token)
            .json(&request)
            .send()
            .await
            .map_err(|e| PabloError::ApiClient {
                status_code: 0,
                message: e.to_string(),
            })?;

        if !response.status().is_success() {
            return Err(handle_error_response(response).await);
        }

        response
            .json::<SoapEntryStatus>()
            .await
            .map_err(|e| PabloError::JsonParse {
                message: e.to_string(),
            })
    })
    .await
}

/// Poll the current status of a SOAP entry job.
///
/// The native UI calls this on a timer (e.g. every 2s) to update the
/// progress display. Returns the current phase, optional preview of what
/// will be entered, and whether confirmation is required.
pub async fn poll_soap_entry_status(
    base_url: String,
    token: String,
    session_id: String,
) -> Result<SoapEntryStatus, PabloError> {
    Compat::new(async move {
        let client = ApiClient::new(base_url);
        let token = SecretString::from(token);

        let response = client
            .get(
                &format!("/api/sessions/{session_id}/soap-entry-status"),
                &token,
            )
            .send()
            .await
            .map_err(|e| PabloError::ApiClient {
                status_code: 0,
                message: e.to_string(),
            })?;

        if !response.status().is_success() {
            return Err(handle_error_response(response).await);
        }

        response
            .json::<SoapEntryStatus>()
            .await
            .map_err(|e| PabloError::JsonParse {
                message: e.to_string(),
            })
    })
    .await
}

/// Confirm that the backend should commit the SOAP note into the EHR.
///
/// Called after the therapist reviews the preview and taps [Confirm].
/// The backend finalizes the Playwright session (clicks "Save" in the EHR).
pub async fn confirm_soap_entry(
    base_url: String,
    token: String,
    session_id: String,
) -> Result<SoapEntryStatus, PabloError> {
    Compat::new(async move {
        let client = ApiClient::new(base_url);
        let token = SecretString::from(token);

        let response = client
            .post(
                &format!("/api/sessions/{session_id}/soap-entry-confirm"),
                &token,
            )
            .send()
            .await
            .map_err(|e| PabloError::ApiClient {
                status_code: 0,
                message: e.to_string(),
            })?;

        if !response.status().is_success() {
            return Err(handle_error_response(response).await);
        }

        response
            .json::<SoapEntryStatus>()
            .await
            .map_err(|e| PabloError::JsonParse {
                message: e.to_string(),
            })
    })
    .await
}

/// Cancel an in-progress SOAP entry job.
///
/// Tells the backend to tear down the Playwright session without saving.
/// Safe to call at any phase — the backend will clean up gracefully.
pub async fn cancel_soap_entry(
    base_url: String,
    token: String,
    session_id: String,
) -> Result<SoapEntryStatus, PabloError> {
    Compat::new(async move {
        let client = ApiClient::new(base_url);
        let token = SecretString::from(token);

        let response = client
            .post(
                &format!("/api/sessions/{session_id}/soap-entry-cancel"),
                &token,
            )
            .send()
            .await
            .map_err(|e| PabloError::ApiClient {
                status_code: 0,
                message: e.to_string(),
            })?;

        if !response.status().is_success() {
            return Err(handle_error_response(response).await);
        }

        response
            .json::<SoapEntryStatus>()
            .await
            .map_err(|e| PabloError::JsonParse {
                message: e.to_string(),
            })
    })
    .await
}

// ── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{SoapEntryConfirmation, SoapEntryPhase, SoapEntryRequest};

    #[test]
    fn soap_entry_request_serialization() {
        let req = SoapEntryRequest {
            ehr_system: "simplepractice".to_string(),
            soap_note_id: "note-001".to_string(),
            patient_name: "Jane Smith".to_string(),
            appointment_time: "2026-03-23T14:00:00Z".to_string(),
        };
        let json = serde_json::to_string(&req).unwrap();
        assert!(json.contains("simplepractice"));
        assert!(json.contains("note-001"));
    }

    #[test]
    fn soap_entry_status_deserialization() {
        let json = r#"{
            "job_id": "job-123",
            "phase": "awaiting_confirmation",
            "message": "Found patient Jane S. — 2:00 PM appointment",
            "patient_match": "Jane Smith",
            "appointment_match": "2:00 PM on March 23",
            "ehr_target_field": "Patient Notes → Today's Session",
            "error": null
        }"#;
        let status: SoapEntryStatus = serde_json::from_str(json).unwrap();
        assert_eq!(status.job_id, "job-123");
        assert_eq!(status.phase, "awaiting_confirmation");
        assert_eq!(status.patient_match.as_deref(), Some("Jane Smith"));
        assert!(status.error.is_none());
    }

    #[test]
    fn soap_entry_phase_serde_roundtrip() {
        let phases = vec![
            SoapEntryPhase::Queued,
            SoapEntryPhase::Navigating,
            SoapEntryPhase::MatchingPatient,
            SoapEntryPhase::AwaitingConfirmation,
            SoapEntryPhase::Entering,
            SoapEntryPhase::Completed,
            SoapEntryPhase::Failed,
            SoapEntryPhase::Cancelled,
        ];
        for phase in phases {
            let json = serde_json::to_string(&phase).unwrap();
            let parsed: SoapEntryPhase = serde_json::from_str(&json).unwrap();
            assert_eq!(parsed, phase);
        }
    }

    #[test]
    fn soap_entry_confirmation_serialization() {
        let confirmation = SoapEntryConfirmation {
            patient_match: "Jane Smith".to_string(),
            appointment_match: "2:00 PM on March 23".to_string(),
            ehr_target_field: "Patient Notes → Today's Session".to_string(),
            soap_preview: Some("S: Patient reports improved mood...".to_string()),
        };
        let json = serde_json::to_string(&confirmation).unwrap();
        assert!(json.contains("Jane Smith"));
        assert!(json.contains("soap_preview"));
    }
}
