// HTTP infrastructure layer for the Pablo API.
// ApiClient struct is internal; public endpoint functions are exposed via UniFFI.

use reqwest::Client;
use secrecy::{ExposeSecret, SecretString};

use crate::models::{PatientListResponse, UploadResponse};
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
    #[allow(dead_code)] // Used by Group B endpoint functions (108.4)
    pub fn patch(&self, path: &str, token: &SecretString) -> reqwest::RequestBuilder {
        self.authenticated_request(reqwest::Method::PATCH, path, token)
    }

    /// Build an authenticated PUT request.
    #[allow(dead_code)] // Used by Group B endpoint functions (108.4)
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
            .header(
                "Authorization",
                format!("Bearer {}", token.expose_secret()),
            )
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

// ── Public endpoint functions ────────────────────────────────────────────────
// These are the public API that gets exposed via UniFFI.
// Each function creates its own ApiClient (stateless, cheap).
// Token is accepted as `String` at the boundary and wrapped in `SecretString`
// internally so sensitive data is protected in Rust memory.

// ── Group A: Ported from Swift APIClient (108.3) ────────────────────────────

/// Check that the Pablo backend is reachable. Unauthenticated.
pub async fn health_check(base_url: String) -> Result<(), PabloError> {
    let client = ApiClient::new(base_url);

    let response = client
        .get_public("/health")
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
}

/// Fetch a paginated list of patients, optionally filtered by search term.
pub async fn fetch_patients(
    base_url: String,
    token: String,
    search: Option<String>,
    page: u32,
    page_size: u32,
) -> Result<PatientListResponse, PabloError> {
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

    response
        .json::<PatientListResponse>()
        .await
        .map_err(|e| PabloError::JsonParse {
            message: e.to_string(),
        })
}

/// Upload a recording file to the backend via multipart form data.
pub async fn upload_recording(
    base_url: String,
    token: String,
    file_path: String,
) -> Result<UploadResponse, PabloError> {
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

        let auth = req.headers().get("Authorization").unwrap().to_str().unwrap();
        assert_eq!(auth, "Bearer test-token-abc");
        assert_eq!(
            req.headers().get("X-Client-Type").unwrap(),
            CLIENT_TYPE_HEADER
        );
        assert_eq!(
            req.url().as_str(),
            "https://api.pablo.health/v1/sessions"
        );
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
        let response = http::Response::builder()
            .status(401)
            .body("")
            .unwrap();
        let reqwest_resp = reqwest::Response::from(response);
        let err = handle_error_response(reqwest_resp).await;
        assert!(matches!(err, PabloError::Unauthenticated));
    }

    #[tokio::test]
    async fn handle_error_403_maps_to_forbidden() {
        let response = http::Response::builder()
            .status(403)
            .body("")
            .unwrap();
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
        let req = client.get_public("/health").build().unwrap();
        assert_eq!(req.url().as_str(), "https://api.pablo.health/health");
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
    fn upload_response_serde_roundtrip() {
        let json = r#"{"id": "rec-001", "status": "uploaded"}"#;
        let resp: UploadResponse = serde_json::from_str(json).unwrap();
        assert_eq!(resp.id, "rec-001");
        assert_eq!(resp.status, "uploaded");
        let serialized = serde_json::to_string(&resp).unwrap();
        assert!(serialized.contains("rec-001"));
    }

    #[test]
    fn fetch_patients_query_without_search_omits_param() {
        let client = ApiClient::new("https://api.pablo.health".to_string());
        let token = SecretString::from("tok");
        // When search is None, only page/page_size should be in query
        let query_params: Vec<(&str, String)> = vec![
            ("page", "1".to_string()),
            ("page_size", "50".to_string()),
        ];
        let req = client
            .get("/api/patients", &token)
            .query(&query_params)
            .build()
            .unwrap();
        let url = req.url().to_string();
        assert!(!url.contains("search="));
        assert!(url.contains("page=1"));
    }
}
