// HTTP infrastructure layer for the Pablo API.
// ApiClient struct is internal; public endpoint functions are exposed via UniFFI.

use async_compat::Compat;
use reqwest::Client;
use secrecy::{ExposeSecret, SecretString};

use crate::models::{
    BaaStatus, CreatePatientRequest, CreateSessionRequest, Patient, PatientListResponse, Session,
    SessionListResponse, SessionStatus, TranscriptUploadResponse, UpdateSessionRequest,
    UploadResponse, UserPreferences, UserProfile,
};
use crate::PabloError;

/// Client-type header value sent with every request so the backend
/// can distinguish companion traffic from web traffic.
const CLIENT_TYPE_HEADER: &str = "pablo-companion-macos/1.0";

/// Shared HTTP helper for authenticated Pablo API requests.
///
/// Holds a reusable `reqwest::Client` and the base URL. Each method
/// returns a `RequestBuilder` so callers can chain `.json()`, `.query()`, etc.
/// before `.send()`.
pub(crate) struct ApiClient {
    client: Client,
    base_url: String,
}

impl ApiClient {
    /// Create a new `ApiClient` pointing at the given base URL
    /// (e.g. `"https://api.pablo.health"`).
    pub fn new(base_url: String) -> Self {
        Self {
            client: Client::new(),
            base_url,
        }
    }

    /// The base URL this client was configured with.
    #[cfg(test)]
    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    /// Build an authenticated GET request.
    pub fn get(&self, path: &str, token: &SecretString) -> reqwest::RequestBuilder {
        self.authenticated_request(reqwest::Method::GET, path, token)
    }

    /// Build an authenticated POST request.
    pub fn post(&self, path: &str, token: &SecretString) -> reqwest::RequestBuilder {
        self.authenticated_request(reqwest::Method::POST, path, token)
    }

    /// Build an authenticated PATCH request.
    pub fn patch(&self, path: &str, token: &SecretString) -> reqwest::RequestBuilder {
        self.authenticated_request(reqwest::Method::PATCH, path, token)
    }

    /// Build an authenticated PUT request.
    pub fn put(&self, path: &str, token: &SecretString) -> reqwest::RequestBuilder {
        self.authenticated_request(reqwest::Method::PUT, path, token)
    }

    /// Build an unauthenticated GET (for health-check, version, etc.).
    pub fn get_public(&self, path: &str) -> reqwest::RequestBuilder {
        self.client
            .get(format!("{}{}", self.base_url, path))
            .header("X-Client-Type", CLIENT_TYPE_HEADER)
    }

    // ── private helper ──────────────────────────────────────────────────────

    fn authenticated_request(
        &self,
        method: reqwest::Method,
        path: &str,
        token: &SecretString,
    ) -> reqwest::RequestBuilder {
        self.client
            .request(method, format!("{}{}", self.base_url, path))
            .header("Authorization", format!("Bearer {}", token.expose_secret()))
            .header("X-Client-Type", CLIENT_TYPE_HEADER)
    }
}

/// Map a non-success HTTP response to the appropriate `PabloError` variant.
///
/// The Pablo backend returns JSON error bodies like:
/// ```json
/// { "detail": "...", "error_code": "...", "field": "..." }
/// ```
/// For now we pass the raw body as the error message; structured parsing
/// can be added later when the backend error contract stabilises.
pub(crate) async fn handle_error_response(response: reqwest::Response) -> PabloError {
    let status = response.status().as_u16();

    match status {
        401 => PabloError::Unauthenticated,
        403 => PabloError::Forbidden,
        404 => {
            let body = response.text().await.unwrap_or_default();
            PabloError::NotFound { resource: body }
        }
        409 => {
            let body = response.text().await.unwrap_or_default();
            PabloError::ConflictState { message: body }
        }
        _ => {
            let body = response.text().await.unwrap_or_default();
            PabloError::ApiClient {
                status_code: status,
                message: body,
            }
        }
    }
}

/// Format a JSON parse error with context around the error position.
fn format_json_error(err: &serde_json::Error, body: &str) -> String {
    let col = err.column();
    if col > 0 && col <= body.len() {
        let start = col.saturating_sub(40);
        let end = (col + 40).min(body.len());
        let snippet = &body[start..end];
        // Show hex bytes around the error position for debugging
        let error_byte = body.as_bytes().get(col.saturating_sub(1));
        let hex = error_byte.map_or("N/A".to_string(), |b| format!("0x{b:02X}"));
        format!("{err}\nByte at column {col}: {hex}\nContext: ...{snippet}...")
    } else {
        format!("{err}\nBody length: {}", body.len())
    }
}

/// Sanitize a JSON response body by fixing invalid escape sequences.
///
/// The backend may store transcript content with Python-style `\'` escapes
/// which are not valid JSON (JSON only allows `\"`, `\\`, `\/`, `\b`, `\f`,
/// `\n`, `\r`, `\t`, `\uXXXX`). This replaces `\'` with `'` before parsing.
fn sanitize_json(input: &str) -> String {
    input.replace("\\'", "'")
}

// ── Public endpoint functions ────────────────────────────────────────────────
// These are the public API that gets exposed via UniFFI.
// Each function creates its own ApiClient (stateless, cheap).
// Token is accepted as `String` at the boundary and wrapped in `SecretString`
// internally so sensitive data is protected in Rust memory.

// ── Group A: Ported from Swift APIClient (108.3) ────────────────────────────

/// Check that the Pablo backend is reachable. Unauthenticated.
pub async fn health_check(base_url: String) -> Result<(), PabloError> {
    Compat::new(async move {
        let client = ApiClient::new(base_url);

        let response =
            client
                .get_public("/api/health")
                .send()
                .await
                .map_err(|e| PabloError::ApiClient {
                    status_code: 0,
                    message: e.to_string(),
                })?;

        if !response.status().is_success() {
            return Err(handle_error_response(response).await);
        }

        Ok(())
    })
    .await
}

/// Fetch a paginated list of patients, optionally filtered by search term.
pub async fn fetch_patients(
    base_url: String,
    token: String,
    search: Option<String>,
    page: u32,
    page_size: u32,
) -> Result<PatientListResponse, PabloError> {
    Compat::new(async move {
        let client = ApiClient::new(base_url);
        let token = SecretString::from(token);

        let mut query_params: Vec<(&str, String)> = vec![
            ("page", page.to_string()),
            ("page_size", page_size.to_string()),
        ];
        if let Some(ref s) = search {
            query_params.push(("search", s.clone()));
        }

        let response = client
            .get("/api/patients", &token)
            .query(&query_params)
            .send()
            .await
            .map_err(|e| PabloError::ApiClient {
                status_code: 0,
                message: e.to_string(),
            })?;

        if !response.status().is_success() {
            return Err(handle_error_response(response).await);
        }

        let body = response.text().await.map_err(|e| PabloError::JsonParse {
            message: e.to_string(),
        })?;
        serde_json::from_str::<PatientListResponse>(&body).map_err(|e| PabloError::JsonParse {
            message: format!("{e}\nResponse body: {body}"),
        })
    })
    .await
}

/// Upload a recording file to the backend via multipart form data.
pub async fn upload_recording(
    base_url: String,
    token: String,
    file_path: String,
) -> Result<UploadResponse, PabloError> {
    Compat::new(async move {
        let client = ApiClient::new(base_url);
        let token = SecretString::from(token);

        let file_bytes = tokio::fs::read(&file_path)
            .await
            .map_err(|e| PabloError::ApiClient {
                status_code: 0,
                message: format!("Failed to read file: {e}"),
            })?;

        let file_name = std::path::Path::new(&file_path)
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .to_string();

        let part = reqwest::multipart::Part::bytes(file_bytes)
            .file_name(file_name)
            .mime_str("application/octet-stream")
            .map_err(|e| PabloError::ApiClient {
                status_code: 0,
                message: e.to_string(),
            })?;

        let form = reqwest::multipart::Form::new().part("file", part);

        let response = client
            .post("/api/recordings/upload", &token)
            .multipart(form)
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
            .json::<UploadResponse>()
            .await
            .map_err(|e| PabloError::JsonParse {
                message: e.to_string(),
            })
    })
    .await
}

// ── Group B: New API methods (108.4) ────────────────────────────────────────

/// Fetch today's sessions for the authenticated therapist.
pub async fn fetch_today_sessions(
    base_url: String,
    token: String,
    timezone: String,
) -> Result<Vec<Session>, PabloError> {
    Compat::new(async move {
        let client = ApiClient::new(base_url);
        let token = SecretString::from(token);

        let response = client
            .get("/api/sessions/today", &token)
            .query(&[("timezone", &timezone)])
            .send()
            .await
            .map_err(|e| PabloError::ApiClient {
                status_code: 0,
                message: e.to_string(),
            })?;

        if !response.status().is_success() {
            return Err(handle_error_response(response).await);
        }

        let body = response.text().await.map_err(|e| PabloError::JsonParse {
            message: e.to_string(),
        })?;
        let sanitized = sanitize_json(&body);
        let list: SessionListResponse =
            serde_json::from_str(&sanitized).map_err(|e| PabloError::JsonParse {
                message: format_json_error(&e, &sanitized),
            })?;
        Ok(list.data)
    })
    .await
}

/// Create a new scheduled session.
pub async fn create_session(
    base_url: String,
    token: String,
    request: CreateSessionRequest,
) -> Result<Session, PabloError> {
    Compat::new(async move {
        let client = ApiClient::new(base_url);
        let token = SecretString::from(token);

        let response = client
            .post("/api/sessions/schedule", &token)
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
            .json::<Session>()
            .await
            .map_err(|e| PabloError::JsonParse {
                message: e.to_string(),
            })
    })
    .await
}

/// Update the status of a session (e.g. start, complete, cancel).
pub async fn update_session_status(
    base_url: String,
    token: String,
    session_id: String,
    status: SessionStatus,
) -> Result<Session, PabloError> {
    Compat::new(async move {
        let client = ApiClient::new(base_url);
        let token = SecretString::from(token);

        let body = serde_json::json!({ "status": status });

        let response = client
            .patch(&format!("/api/sessions/{session_id}/status"), &token)
            .json(&body)
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
            .json::<Session>()
            .await
            .map_err(|e| PabloError::JsonParse {
                message: e.to_string(),
            })
    })
    .await
}

/// Update editable fields on a session.
pub async fn update_session(
    base_url: String,
    token: String,
    session_id: String,
    request: UpdateSessionRequest,
) -> Result<Session, PabloError> {
    Compat::new(async move {
        let client = ApiClient::new(base_url);
        let token = SecretString::from(token);

        let response = client
            .patch(&format!("/api/sessions/{session_id}"), &token)
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
            .json::<Session>()
            .await
            .map_err(|e| PabloError::JsonParse {
                message: e.to_string(),
            })
    })
    .await
}

/// Fetch a single session by ID.
pub async fn fetch_session(
    base_url: String,
    token: String,
    session_id: String,
) -> Result<Session, PabloError> {
    Compat::new(async move {
        let client = ApiClient::new(base_url);
        let token = SecretString::from(token);

        let response = client
            .get(&format!("/api/sessions/{session_id}"), &token)
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
            .json::<Session>()
            .await
            .map_err(|e| PabloError::JsonParse {
                message: e.to_string(),
            })
    })
    .await
}

/// Fetch a paginated list of sessions, optionally filtered by status.
pub async fn fetch_sessions(
    base_url: String,
    token: String,
    page: u32,
    page_size: u32,
    status: Option<String>,
) -> Result<SessionListResponse, PabloError> {
    Compat::new(async move {
        let client = ApiClient::new(base_url);
        let token = SecretString::from(token);

        let mut query_params: Vec<(&str, String)> = vec![
            ("page", page.to_string()),
            ("page_size", page_size.to_string()),
        ];
        if let Some(ref s) = status {
            query_params.push(("status", s.clone()));
        }

        let response = client
            .get("/api/sessions", &token)
            .query(&query_params)
            .send()
            .await
            .map_err(|e| PabloError::ApiClient {
                status_code: 0,
                message: e.to_string(),
            })?;

        if !response.status().is_success() {
            return Err(handle_error_response(response).await);
        }

        let body = response.text().await.map_err(|e| PabloError::JsonParse {
            message: e.to_string(),
        })?;
        let sanitized = sanitize_json(&body);
        serde_json::from_str::<SessionListResponse>(&sanitized).map_err(|e| PabloError::JsonParse {
            message: format_json_error(&e, &sanitized),
        })
    })
    .await
}

/// Upload a transcript for a session.
pub async fn upload_transcript(
    base_url: String,
    token: String,
    session_id: String,
    format: String,
    content: String,
) -> Result<TranscriptUploadResponse, PabloError> {
    Compat::new(async move {
        let client = ApiClient::new(base_url);
        let token = SecretString::from(token);

        let body = serde_json::json!({
            "format": format,
            "content": content,
        });

        let response = client
            .post(&format!("/api/sessions/{session_id}/transcript"), &token)
            .json(&body)
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
            .json::<TranscriptUploadResponse>()
            .await
            .map_err(|e| PabloError::JsonParse {
                message: e.to_string(),
            })
    })
    .await
}

/// Finalize a session with a quality rating.
pub async fn finalize_session(
    base_url: String,
    token: String,
    session_id: String,
    quality_rating: u8,
) -> Result<Session, PabloError> {
    Compat::new(async move {
        let client = ApiClient::new(base_url);
        let token = SecretString::from(token);

        let body = serde_json::json!({ "quality_rating": quality_rating });

        let response = client
            .patch(&format!("/api/sessions/{session_id}/finalize"), &token)
            .json(&body)
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
            .json::<Session>()
            .await
            .map_err(|e| PabloError::JsonParse {
                message: e.to_string(),
            })
    })
    .await
}

/// Fetch the authenticated user's profile.
pub async fn fetch_user_profile(
    base_url: String,
    token: String,
) -> Result<UserProfile, PabloError> {
    Compat::new(async move {
        let client = ApiClient::new(base_url);
        let token = SecretString::from(token);

        let response = client
            .get("/api/users/me", &token)
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
            .json::<UserProfile>()
            .await
            .map_err(|e| PabloError::JsonParse {
                message: e.to_string(),
            })
    })
    .await
}

/// Fetch the user's BAA acceptance status.
pub async fn fetch_baa_status(base_url: String, token: String) -> Result<BaaStatus, PabloError> {
    Compat::new(async move {
        let client = ApiClient::new(base_url);
        let token = SecretString::from(token);

        let response = client
            .get("/api/users/me/baa-status", &token)
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
            .json::<BaaStatus>()
            .await
            .map_err(|e| PabloError::JsonParse {
                message: e.to_string(),
            })
    })
    .await
}

/// Accept the BAA agreement.
pub async fn accept_baa(base_url: String, token: String) -> Result<BaaStatus, PabloError> {
    Compat::new(async move {
        let client = ApiClient::new(base_url);
        let token = SecretString::from(token);

        let response = client
            .post("/api/users/me/accept-baa", &token)
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
            .json::<BaaStatus>()
            .await
            .map_err(|e| PabloError::JsonParse {
                message: e.to_string(),
            })
    })
    .await
}

/// Fetch the user's preferences.
pub async fn fetch_preferences(
    base_url: String,
    token: String,
) -> Result<UserPreferences, PabloError> {
    Compat::new(async move {
        let client = ApiClient::new(base_url);
        let token = SecretString::from(token);

        let response = client
            .get("/api/users/me/preferences", &token)
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
            .json::<UserPreferences>()
            .await
            .map_err(|e| PabloError::JsonParse {
                message: e.to_string(),
            })
    })
    .await
}

/// Save (replace) the user's preferences.
pub async fn save_preferences(
    base_url: String,
    token: String,
    preferences: UserPreferences,
) -> Result<UserPreferences, PabloError> {
    Compat::new(async move {
        let client = ApiClient::new(base_url);
        let token = SecretString::from(token);

        let response = client
            .put("/api/users/me/preferences", &token)
            .json(&preferences)
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
            .json::<UserPreferences>()
            .await
            .map_err(|e| PabloError::JsonParse {
                message: e.to_string(),
            })
    })
    .await
}

/// Create a new patient record.
pub async fn create_patient(
    base_url: String,
    token: String,
    request: CreatePatientRequest,
) -> Result<Patient, PabloError> {
    Compat::new(async move {
        let client = ApiClient::new(base_url);
        let token = SecretString::from(token);

        let response = client
            .post("/api/patients", &token)
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
            .json::<Patient>()
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

    #[test]
    fn api_client_stores_base_url() {
        let client = ApiClient::new("https://api.pablo.health".to_string());
        assert_eq!(client.base_url(), "https://api.pablo.health");
    }

    #[test]
    fn get_public_builds_correct_url() {
        let client = ApiClient::new("https://api.pablo.health".to_string());
        let req = client.get_public("/health").build().unwrap();
        assert_eq!(req.url().as_str(), "https://api.pablo.health/health");
    }

    #[test]
    fn get_public_includes_client_type_header() {
        let client = ApiClient::new("https://api.pablo.health".to_string());
        let req = client.get_public("/health").build().unwrap();
        assert_eq!(
            req.headers().get("X-Client-Type").unwrap(),
            CLIENT_TYPE_HEADER
        );
    }

    #[test]
    fn get_public_has_no_auth_header() {
        let client = ApiClient::new("https://api.pablo.health".to_string());
        let req = client.get_public("/health").build().unwrap();
        assert!(req.headers().get("Authorization").is_none());
    }

    #[test]
    fn authenticated_get_includes_bearer_token() {
        let client = ApiClient::new("https://api.pablo.health".to_string());
        let token = SecretString::from("test-token-abc");
        let req = client.get("/v1/sessions", &token).build().unwrap();

        let auth = req
            .headers()
            .get("Authorization")
            .unwrap()
            .to_str()
            .unwrap();
        assert_eq!(auth, "Bearer test-token-abc");
        assert_eq!(
            req.headers().get("X-Client-Type").unwrap(),
            CLIENT_TYPE_HEADER
        );
        assert_eq!(req.url().as_str(), "https://api.pablo.health/v1/sessions");
    }

    #[test]
    fn authenticated_post_uses_post_method() {
        let client = ApiClient::new("https://api.pablo.health".to_string());
        let token = SecretString::from("tok");
        let req = client.post("/v1/sessions", &token).build().unwrap();
        assert_eq!(req.method(), reqwest::Method::POST);
    }

    #[test]
    fn authenticated_patch_uses_patch_method() {
        let client = ApiClient::new("https://api.pablo.health".to_string());
        let token = SecretString::from("tok");
        let req = client.patch("/v1/sessions/123", &token).build().unwrap();
        assert_eq!(req.method(), reqwest::Method::PATCH);
    }

    #[test]
    fn authenticated_put_uses_put_method() {
        let client = ApiClient::new("https://api.pablo.health".to_string());
        let token = SecretString::from("tok");
        let req = client.put("/v1/preferences", &token).build().unwrap();
        assert_eq!(req.method(), reqwest::Method::PUT);
    }

    #[test]
    fn token_not_leaked_in_debug() {
        // SecretString's Debug impl should NOT print the actual token value.
        let token = SecretString::from("super-secret-value");
        let debug_output = format!("{:?}", token);
        assert!(
            !debug_output.contains("super-secret-value"),
            "Token was leaked in Debug output: {debug_output}"
        );
    }

    #[tokio::test]
    async fn handle_error_401_maps_to_unauthenticated() {
        let response = http::Response::builder().status(401).body("").unwrap();
        let reqwest_resp = reqwest::Response::from(response);
        let err = handle_error_response(reqwest_resp).await;
        assert!(matches!(err, PabloError::Unauthenticated));
    }

    #[tokio::test]
    async fn handle_error_403_maps_to_forbidden() {
        let response = http::Response::builder().status(403).body("").unwrap();
        let reqwest_resp = reqwest::Response::from(response);
        let err = handle_error_response(reqwest_resp).await;
        assert!(matches!(err, PabloError::Forbidden));
    }

    #[tokio::test]
    async fn handle_error_404_maps_to_not_found() {
        let response = http::Response::builder()
            .status(404)
            .body("session not found")
            .unwrap();
        let reqwest_resp = reqwest::Response::from(response);
        let err = handle_error_response(reqwest_resp).await;
        match err {
            PabloError::NotFound { resource } => {
                assert_eq!(resource, "session not found");
            }
            other => panic!("Expected NotFound, got: {other:?}"),
        }
    }

    #[tokio::test]
    async fn handle_error_409_maps_to_conflict() {
        let response = http::Response::builder()
            .status(409)
            .body("session already started")
            .unwrap();
        let reqwest_resp = reqwest::Response::from(response);
        let err = handle_error_response(reqwest_resp).await;
        match err {
            PabloError::ConflictState { message } => {
                assert_eq!(message, "session already started");
            }
            other => panic!("Expected ConflictState, got: {other:?}"),
        }
    }

    #[tokio::test]
    async fn handle_error_500_maps_to_api_client() {
        let response = http::Response::builder()
            .status(500)
            .body("internal server error")
            .unwrap();
        let reqwest_resp = reqwest::Response::from(response);
        let err = handle_error_response(reqwest_resp).await;
        match err {
            PabloError::ApiClient {
                status_code,
                message,
            } => {
                assert_eq!(status_code, 500);
                assert_eq!(message, "internal server error");
            }
            other => panic!("Expected ApiClient, got: {other:?}"),
        }
    }

    #[tokio::test]
    async fn handle_error_422_maps_to_api_client() {
        let response = http::Response::builder()
            .status(422)
            .body("validation error")
            .unwrap();
        let reqwest_resp = reqwest::Response::from(response);
        let err = handle_error_response(reqwest_resp).await;
        match err {
            PabloError::ApiClient {
                status_code,
                message,
            } => {
                assert_eq!(status_code, 422);
                assert_eq!(message, "validation error");
            }
            other => panic!("Expected ApiClient, got: {other:?}"),
        }
    }

    // ── Endpoint function tests (request building) ──────────────────────────

    #[test]
    fn health_check_builds_unauthenticated_get_to_health() {
        let client = ApiClient::new("https://api.pablo.health".to_string());
        let req = client.get_public("/api/health").build().unwrap();
        assert_eq!(req.url().as_str(), "https://api.pablo.health/api/health");
        assert_eq!(req.method(), reqwest::Method::GET);
        assert!(req.headers().get("Authorization").is_none());
    }

    #[test]
    fn fetch_patients_builds_correct_url_with_query_params() {
        let client = ApiClient::new("https://api.pablo.health".to_string());
        let token = SecretString::from("tok");
        let req = client
            .get("/api/patients", &token)
            .query(&[("page", "1"), ("page_size", "50"), ("search", "Smith")])
            .build()
            .unwrap();
        let url = req.url().to_string();
        assert!(url.starts_with("https://api.pablo.health/api/patients?"));
        assert!(url.contains("page=1"));
        assert!(url.contains("page_size=50"));
        assert!(url.contains("search=Smith"));
    }

    #[test]
    fn upload_recording_builds_post_to_recordings_upload() {
        let client = ApiClient::new("https://api.pablo.health".to_string());
        let token = SecretString::from("tok");
        let req = client
            .post("/api/recordings/upload", &token)
            .build()
            .unwrap();
        assert_eq!(
            req.url().as_str(),
            "https://api.pablo.health/api/recordings/upload"
        );
        assert_eq!(req.method(), reqwest::Method::POST);
    }

    #[test]
    fn fetch_today_sessions_builds_correct_url_with_timezone() {
        let client = ApiClient::new("https://api.pablo.health".to_string());
        let token = SecretString::from("tok");
        let req = client
            .get("/api/sessions/today", &token)
            .query(&[("timezone", "America/New_York")])
            .build()
            .unwrap();
        let url = req.url().to_string();
        assert!(url.starts_with("https://api.pablo.health/api/sessions/today?"));
        assert!(url.contains("timezone=America"));
    }

    #[test]
    fn create_session_builds_post_to_sessions_schedule() {
        let client = ApiClient::new("https://api.pablo.health".to_string());
        let token = SecretString::from("tok");
        let request = CreateSessionRequest {
            patient_id: "pat-001".to_string(),
            scheduled_at: "2026-03-07T10:00:00Z".to_string(),
            duration_minutes: Some(50),
            video_link: None,
            video_platform: None,
            session_type: None,
            source: None,
            notes: None,
        };
        let req = client
            .post("/api/sessions/schedule", &token)
            .json(&request)
            .build()
            .unwrap();
        assert_eq!(
            req.url().as_str(),
            "https://api.pablo.health/api/sessions/schedule"
        );
        assert_eq!(req.method(), reqwest::Method::POST);
        // Verify body contains patient_id
        let body = req.body().unwrap().as_bytes().unwrap();
        let body_str = String::from_utf8_lossy(body);
        assert!(body_str.contains("pat-001"));
        assert!(body_str.contains("2026-03-07T10:00:00Z"));
    }

    #[test]
    fn update_session_status_builds_patch_with_status_body() {
        let client = ApiClient::new("https://api.pablo.health".to_string());
        let token = SecretString::from("tok");
        let body = serde_json::json!({ "status": SessionStatus::InProgress });
        let req = client
            .patch("/api/sessions/sess-001/status", &token)
            .json(&body)
            .build()
            .unwrap();
        assert_eq!(
            req.url().as_str(),
            "https://api.pablo.health/api/sessions/sess-001/status"
        );
        assert_eq!(req.method(), reqwest::Method::PATCH);
        let body_bytes = req.body().unwrap().as_bytes().unwrap();
        let body_str = String::from_utf8_lossy(body_bytes);
        assert!(body_str.contains("in_progress"));
    }

    #[test]
    fn update_session_builds_patch_to_session_id() {
        let client = ApiClient::new("https://api.pablo.health".to_string());
        let token = SecretString::from("tok");
        let request = UpdateSessionRequest {
            scheduled_at: None,
            video_link: Some("https://zoom.us/j/123".to_string()),
            video_platform: Some(crate::models::VideoPlatform::Zoom),
            duration_minutes: None,
            notes: None,
        };
        let req = client
            .patch("/api/sessions/sess-001", &token)
            .json(&request)
            .build()
            .unwrap();
        assert_eq!(
            req.url().as_str(),
            "https://api.pablo.health/api/sessions/sess-001"
        );
        let body_bytes = req.body().unwrap().as_bytes().unwrap();
        let body_str = String::from_utf8_lossy(body_bytes);
        assert!(body_str.contains("zoom.us"));
    }

    #[test]
    fn fetch_session_builds_get_to_session_id() {
        let client = ApiClient::new("https://api.pablo.health".to_string());
        let token = SecretString::from("tok");
        let req = client
            .get("/api/sessions/sess-abc", &token)
            .build()
            .unwrap();
        assert_eq!(
            req.url().as_str(),
            "https://api.pablo.health/api/sessions/sess-abc"
        );
        assert_eq!(req.method(), reqwest::Method::GET);
    }

    #[test]
    fn fetch_sessions_builds_correct_url_with_pagination() {
        let client = ApiClient::new("https://api.pablo.health".to_string());
        let token = SecretString::from("tok");
        let req = client
            .get("/api/sessions", &token)
            .query(&[("page", "2"), ("page_size", "25"), ("status", "scheduled")])
            .build()
            .unwrap();
        let url = req.url().to_string();
        assert!(url.starts_with("https://api.pablo.health/api/sessions?"));
        assert!(url.contains("page=2"));
        assert!(url.contains("page_size=25"));
        assert!(url.contains("status=scheduled"));
    }

    #[test]
    fn upload_transcript_builds_post_to_session_transcript() {
        let client = ApiClient::new("https://api.pablo.health".to_string());
        let token = SecretString::from("tok");
        let body = serde_json::json!({
            "format": "google_meet",
            "content": "transcript text",
        });
        let req = client
            .post("/api/sessions/sess-001/transcript", &token)
            .json(&body)
            .build()
            .unwrap();
        assert_eq!(
            req.url().as_str(),
            "https://api.pablo.health/api/sessions/sess-001/transcript"
        );
        assert_eq!(req.method(), reqwest::Method::POST);
        let body_bytes = req.body().unwrap().as_bytes().unwrap();
        let body_str = String::from_utf8_lossy(body_bytes);
        assert!(body_str.contains("google_meet"));
    }

    #[test]
    fn finalize_session_builds_patch_with_quality_rating() {
        let client = ApiClient::new("https://api.pablo.health".to_string());
        let token = SecretString::from("tok");
        let body = serde_json::json!({ "quality_rating": 4u8 });
        let req = client
            .patch("/api/sessions/sess-001/finalize", &token)
            .json(&body)
            .build()
            .unwrap();
        assert_eq!(
            req.url().as_str(),
            "https://api.pablo.health/api/sessions/sess-001/finalize"
        );
        let body_bytes = req.body().unwrap().as_bytes().unwrap();
        let body_str = String::from_utf8_lossy(body_bytes);
        assert!(body_str.contains("quality_rating"));
        assert!(body_str.contains("4"));
    }

    #[test]
    fn fetch_user_profile_builds_get_to_users_me() {
        let client = ApiClient::new("https://api.pablo.health".to_string());
        let token = SecretString::from("tok");
        let req = client.get("/api/users/me", &token).build().unwrap();
        assert_eq!(req.url().as_str(), "https://api.pablo.health/api/users/me");
        assert_eq!(req.method(), reqwest::Method::GET);
    }

    #[test]
    fn fetch_baa_status_builds_get_to_baa_status() {
        let client = ApiClient::new("https://api.pablo.health".to_string());
        let token = SecretString::from("tok");
        let req = client
            .get("/api/users/me/baa-status", &token)
            .build()
            .unwrap();
        assert_eq!(
            req.url().as_str(),
            "https://api.pablo.health/api/users/me/baa-status"
        );
    }

    #[test]
    fn accept_baa_builds_post_to_accept_baa() {
        let client = ApiClient::new("https://api.pablo.health".to_string());
        let token = SecretString::from("tok");
        let req = client
            .post("/api/users/me/accept-baa", &token)
            .build()
            .unwrap();
        assert_eq!(
            req.url().as_str(),
            "https://api.pablo.health/api/users/me/accept-baa"
        );
        assert_eq!(req.method(), reqwest::Method::POST);
    }

    #[test]
    fn fetch_preferences_builds_get_to_preferences() {
        let client = ApiClient::new("https://api.pablo.health".to_string());
        let token = SecretString::from("tok");
        let req = client
            .get("/api/users/me/preferences", &token)
            .build()
            .unwrap();
        assert_eq!(
            req.url().as_str(),
            "https://api.pablo.health/api/users/me/preferences"
        );
    }

    #[test]
    fn save_preferences_builds_put_with_preferences_body() {
        let client = ApiClient::new("https://api.pablo.health".to_string());
        let token = SecretString::from("tok");
        let prefs = UserPreferences {
            default_video_platform: crate::models::VideoPlatform::Zoom,
            default_session_type: crate::models::SessionType::Individual,
            default_duration_minutes: 50,
            auto_transcribe: true,
            quality_preset: crate::models::QualityPreset::Balanced,
            therapist_display_name: "Dr. Smith".to_string(),
        };
        let req = client
            .put("/api/users/me/preferences", &token)
            .json(&prefs)
            .build()
            .unwrap();
        assert_eq!(
            req.url().as_str(),
            "https://api.pablo.health/api/users/me/preferences"
        );
        assert_eq!(req.method(), reqwest::Method::PUT);
        let body_bytes = req.body().unwrap().as_bytes().unwrap();
        let body_str = String::from_utf8_lossy(body_bytes);
        assert!(body_str.contains("zoom"));
        assert!(body_str.contains("Dr. Smith"));
    }

    #[test]
    fn create_patient_builds_post_with_patient_fields() {
        let client = ApiClient::new("https://api.pablo.health".to_string());
        let token = SecretString::from("tok");
        let body = serde_json::json!({
            "first_name": "Jane",
            "last_name": "Doe",
            "email": "jane@example.com",
            "phone": null,
            "date_of_birth": null,
            "diagnosis": null,
        });
        let req = client
            .post("/api/patients", &token)
            .json(&body)
            .build()
            .unwrap();
        assert_eq!(req.url().as_str(), "https://api.pablo.health/api/patients");
        assert_eq!(req.method(), reqwest::Method::POST);
        let body_bytes = req.body().unwrap().as_bytes().unwrap();
        let body_str = String::from_utf8_lossy(body_bytes);
        assert!(body_str.contains("Jane"));
        assert!(body_str.contains("Doe"));
        assert!(body_str.contains("jane@example.com"));
    }

    #[test]
    fn upload_response_serde_roundtrip() {
        let json = r#"{"id": "rec-001", "status": "uploaded"}"#;
        let resp: UploadResponse = serde_json::from_str(json).unwrap();
        assert_eq!(resp.id, "rec-001");
        assert_eq!(resp.status, "uploaded");
        let serialized = serde_json::to_string(&resp).unwrap();
        assert!(serialized.contains("rec-001"));
    }

    #[test]
    fn session_status_serializes_for_request_body() {
        // Verify SessionStatus serializes to snake_case for API requests
        let body = serde_json::json!({ "status": SessionStatus::InProgress });
        let s = serde_json::to_string(&body).unwrap();
        assert!(s.contains("\"in_progress\""));

        let body = serde_json::json!({ "status": SessionStatus::RecordingComplete });
        let s = serde_json::to_string(&body).unwrap();
        assert!(s.contains("\"recording_complete\""));
    }

    #[test]
    fn create_session_request_serializes_with_optional_fields() {
        let request = CreateSessionRequest {
            patient_id: "pat-001".to_string(),
            scheduled_at: "2026-03-07T10:00:00Z".to_string(),
            duration_minutes: Some(50),
            video_link: None,
            video_platform: Some(crate::models::VideoPlatform::Zoom),
            session_type: None,
            source: Some(crate::models::SessionSource::Companion),
            notes: Some("Initial session".to_string()),
        };
        let json = serde_json::to_string(&request).unwrap();
        assert!(json.contains("pat-001"));
        assert!(json.contains("\"zoom\""));
        assert!(json.contains("\"companion\""));
        assert!(json.contains("Initial session"));
    }

    #[test]
    fn fetch_patients_query_without_search_omits_param() {
        let client = ApiClient::new("https://api.pablo.health".to_string());
        let token = SecretString::from("tok");
        // When search is None, only page/page_size should be in query
        let query_params: Vec<(&str, String)> =
            vec![("page", "1".to_string()), ("page_size", "50".to_string())];
        let req = client
            .get("/api/patients", &token)
            .query(&query_params)
            .build()
            .unwrap();
        let url = req.url().to_string();
        assert!(!url.contains("search="));
        assert!(url.contains("page=1"));
    }

    #[test]
    fn sanitize_json_fixes_invalid_apostrophe_escapes() {
        let input = r#"{"content": "I\'ve been working on it"}"#;
        let sanitized = sanitize_json(input);
        assert_eq!(sanitized, r#"{"content": "I've been working on it"}"#);
        // Verify it's now valid JSON
        let _: serde_json::Value = serde_json::from_str(&sanitized).unwrap();
    }

    #[test]
    fn sanitize_json_preserves_valid_escapes() {
        let input = r#"{"content": "line1\nline2", "path": "C:\\Users"}"#;
        let sanitized = sanitize_json(input);
        assert_eq!(sanitized, input); // No change — all escapes are valid
        let _: serde_json::Value = serde_json::from_str(&sanitized).unwrap();
    }
}
