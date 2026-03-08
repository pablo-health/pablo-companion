# Pablo Companion API Contract

> Defines every backend endpoint the companion app needs, including request/response schemas, auth requirements, and implementation status.

---

## Overview

The Pablo Companion desktop app needs to: fetch today's schedule, start/stop sessions, upload transcripts, display SOAP notes, and manage patients. This contract covers all endpoints — existing ones the companion simply needs to call, and new ones that require backend work.

**Base URL:** Configured per-environment via `GET /api/config` from the auth server.

**Auth:** All `/api/*` endpoints require `Authorization: Bearer <firebase_id_token>` except `/health`. The companion obtains tokens via browser OAuth flow (existing).

**JSON conventions:** All request/response bodies use `snake_case` keys. Companion Swift client uses `.convertFromSnakeCase` decoder strategy.

**Client header:** All requests include `X-Client-Type: pablo-companion-macos/1.0`.

---

## Domain A: Auth & User

All endpoints exist. Companion just needs to call them.

### `GET /health`

Health/connectivity check. No auth required.

```
Response 200:
{ "status": "healthy" }
```

### `GET /api/users/me/status`

Check if authenticated user exists and is active. Used during onboarding.

```
Response 200:
{ "status": "active", "user_id": "uuid" }
```

### `GET /api/users/me`

Load therapist profile. Used for transcript speaker labels.

```
Response 200:
{
  "id": "uuid",
  "email": "dr.lee@example.com",
  "first_name": "Sarah",
  "last_name": "Lee",
  "role": "therapist",
  "created_at": "2026-01-15T10:00:00Z"
}
```

### `GET /api/users/me/baa-status`

Check BAA acceptance status. Onboarding gate.

```
Response 200:
{ "baa_accepted": true, "accepted_at": "2026-01-15T10:05:00Z" }
```

### `POST /api/users/me/accept-baa`

Accept BAA. Onboarding step.

```
Request: (empty body)
Response 200:
{ "baa_accepted": true, "accepted_at": "2026-03-07T14:00:00Z" }
```

---

## Domain B: Patients

All endpoints exist. Companion needs new UI for create/edit.

### `GET /api/patients`

Paginated patient list with optional search.

```
Query: ?search=smith&page=1&page_size=20
Response 200:
{
  "data": [
    {
      "id": "uuid",
      "user_id": "uuid",
      "first_name": "Jane",
      "last_name": "Smith",
      "email": "jane@example.com",
      "phone": "555-0100",
      "status": "active",
      "date_of_birth": "1990-05-15",
      "diagnosis": "Generalized Anxiety",
      "session_count": 12,
      "last_session_date": "2026-03-01T14:00:00Z",
      "next_session_date": "2026-03-08T14:00:00Z",
      "created_at": "2026-01-15T10:00:00Z",
      "updated_at": "2026-03-01T15:00:00Z"
    }
  ],
  "total": 1,
  "page": 1,
  "page_size": 20,
  "has_more": false
}
```

### `GET /api/patients/{id}`

Single patient detail.

```
Response 200: (same Patient object as above)
```

### `POST /api/patients`

Create a new patient.

```
Request:
{
  "first_name": "Jane",
  "last_name": "Smith",
  "email": "jane@example.com",       // optional
  "phone": "555-0100",               // optional
  "date_of_birth": "1990-05-15",     // optional
  "diagnosis": "Generalized Anxiety" // optional
}

Response 201: (full Patient object)
```

### `PATCH /api/patients/{id}`

Update patient fields. Future use.

```
Request:
{ "diagnosis": "Social Anxiety Disorder" }

Response 200: (full Patient object)
```

---

## Domain C: Session Scheduling

**Status: NEW — requires backend implementation.**

These endpoints enable the companion's day view and session lifecycle. The backend currently has no concept of "scheduled" sessions — sessions only exist after a transcript is uploaded.

### Session Status Lifecycle

```
scheduled ──start──> in_progress ──stop──> recording_complete ──transcript──> queued
    |                                                                           |
    v cancel                                                                    v
cancelled                                                    processing > pending_review > finalized
                                                                                          |
                                                                                        failed
```

**New statuses:** `scheduled`, `in_progress`, `recording_complete`, `cancelled`
**Existing statuses (unchanged):** `queued`, `processing`, `pending_review`, `finalized`, `failed`

### New Session Model Fields

| Field | Type | Description |
|-------|------|-------------|
| `scheduled_at` | `datetime?` | When the session is scheduled to start |
| `video_link` | `string?` | Video call URL (Zoom/Teams/Meet link) |
| `video_platform` | `enum?` | `zoom`, `teams`, `meet`, `none` |
| `session_type` | `enum` | `individual`, `couples` |
| `duration_minutes` | `int` | Expected duration (default: 50) |
| `source` | `enum` | `web`, `companion`, `calendar` |
| `started_at` | `datetime?` | When recording actually started |
| `ended_at` | `datetime?` | When recording ended |

### `POST /api/sessions/schedule`

Create a scheduled session (pre-recording).

```
Request:
{
  "patient_id": "uuid",
  "scheduled_at": "2026-03-07T14:00:00Z",
  "duration_minutes": 50,
  "video_link": "https://zoom.us/j/123456789",   // optional
  "video_platform": "zoom",                       // optional: zoom|teams|meet|none
  "session_type": "individual",                    // optional, default: individual
  "source": "companion",                           // optional, default: companion
  "notes": "Follow-up on anxiety management"       // optional
}

Response 201:
{
  "id": "uuid",
  "patient_id": "uuid",
  "status": "scheduled",
  "scheduled_at": "2026-03-07T14:00:00Z",
  "duration_minutes": 50,
  "video_link": "https://zoom.us/j/123456789",
  "video_platform": "zoom",
  "session_type": "individual",
  "source": "companion",
  "notes": "Follow-up on anxiety management",
  "started_at": null,
  "ended_at": null,
  "created_at": "2026-03-07T10:00:00Z",
  "updated_at": "2026-03-07T10:00:00Z"
}

Errors:
  400 — invalid patient_id, scheduled_at in the past, invalid enum value
  404 — patient not found
```

### `GET /api/sessions/today`

Fetch today's sessions for the authenticated therapist, ordered by `scheduled_at` ascending.

```
Query: ?timezone=America/New_York

Response 200:
{
  "data": [
    {
      "id": "uuid",
      "patient_id": "uuid",
      "patient": {
        "id": "uuid",
        "first_name": "Jane",
        "last_name": "Smith"
      },
      "status": "scheduled",
      "scheduled_at": "2026-03-07T14:00:00Z",
      "duration_minutes": 50,
      "video_link": "https://zoom.us/j/123",
      "video_platform": "zoom",
      "session_type": "individual",
      "source": "companion",
      "started_at": null,
      "ended_at": null,
      "created_at": "2026-03-07T10:00:00Z",
      "updated_at": "2026-03-07T10:00:00Z"
    }
  ],
  "total": 5
}

Notes:
  - Day boundary computed server-side from timezone parameter
  - Default timezone: UTC
  - Includes inline patient summary (id, first_name, last_name) to avoid N+1 fetches
```

### `PATCH /api/sessions/{id}/status`

Transition session status. Backend validates the state machine.

```
Request:
{
  "status": "in_progress"    // valid transitions per lifecycle diagram
}

Response 200: (full Session object with updated status)

Side effects by transition:
  scheduled -> in_progress:    sets started_at = now()
  in_progress -> recording_complete:  sets ended_at = now()
  * -> cancelled:              sets ended_at = now() if started_at is set

Errors:
  400 — invalid status transition (e.g., scheduled -> finalized)
  404 — session not found
  409 — session already in target status
```

### `PATCH /api/sessions/{id}`

Update session metadata (reschedule, change video link, etc.).

```
Request:
{
  "scheduled_at": "2026-03-07T15:00:00Z",  // optional
  "video_link": "https://zoom.us/j/999",    // optional
  "video_platform": "zoom",                  // optional
  "duration_minutes": 60,                    // optional
  "notes": "Updated notes"                   // optional
}

Response 200: (full Session object)

Errors:
  400 — cannot modify session in terminal status (finalized, cancelled)
```

---

## Domain D: Transcript Upload

### `POST /api/sessions/{id}/transcript` — NEW

Upload a transcript to an existing session, triggering the SOAP pipeline.

```
Request:
{
  "format": "google_meet",
  "content": "Google Meet Transcript\nSession Date: March 7, 2026\n\nTherapist (00:00:05)\nHi Jane, how have you been?\n\nClient (00:00:12)\nI've been doing better with the breathing exercises."
}

Response 200:
{
  "id": "uuid",
  "status": "queued",
  "message": "Transcript received. SOAP note generation started."
}

Side effects:
  - Transitions session status: recording_complete -> queued
  - Kicks off SOAP note generation pipeline (same as existing upload flow)

Errors:
  400 — session not in recording_complete status
  400 — empty content
  404 — session not found
```

### `POST /api/patients/{patient_id}/sessions/upload` — EXISTING (unchanged)

Existing transcript upload endpoint. Creates a new session and starts SOAP pipeline. Remains for web app and backwards compatibility.

```
Request:
{
  "transcript": "...",
  "format": "google_meet"
}

Response 200:
{
  "session_id": "uuid",
  "status": "queued"
}
```

---

## Domain E: SOAP Notes & Session History

All endpoints exist. Companion provides read-only access + finalization.

### `GET /api/sessions`

Browse past sessions with pagination.

```
Query: ?page=1&page_size=20&status=pending_review
Response 200:
{
  "data": [Session],
  "total": 42,
  "page": 1,
  "page_size": 20,
  "has_more": true
}
```

### `GET /api/sessions/{id}`

Session detail including SOAP note (if generated).

```
Response 200:
{
  "id": "uuid",
  "patient_id": "uuid",
  "patient": { "id": "uuid", "first_name": "Jane", "last_name": "Smith" },
  "status": "pending_review",
  "scheduled_at": "2026-03-07T14:00:00Z",
  "started_at": "2026-03-07T14:01:00Z",
  "ended_at": "2026-03-07T14:50:00Z",
  "session_type": "individual",
  "soap_note": {
    "subjective": "Patient reports improvement with breathing exercises...",
    "objective": "Patient appeared calm, maintained eye contact...",
    "assessment": "Progress noted in anxiety management...",
    "plan": "Continue CBT techniques, next session in one week..."
  },
  "transcript": "...",
  "quality_rating": null,
  "created_at": "2026-03-07T14:00:00Z",
  "updated_at": "2026-03-07T15:05:00Z"
}
```

### `PATCH /api/sessions/{id}/finalize`

Finalize a session with quality rating.

```
Request:
{ "quality_rating": 4 }   // 1-5

Response 200: (full Session object, status = "finalized")

Errors:
  400 — session not in pending_review status
  400 — quality_rating not 1-5
```

---

## Domain F: User Preferences

**Status: NEW — requires backend implementation.**

### `GET /api/users/me/preferences`

Fetch user preferences. Returns defaults if never saved.

```
Response 200:
{
  "default_video_platform": "zoom",       // zoom|teams|meet|none
  "default_session_type": "individual",   // individual|couples
  "default_duration_minutes": 50,
  "auto_transcribe": true,
  "quality_preset": "balanced",           // fast|balanced|accurate
  "therapist_display_name": "Dr. Lee"
}
```

### `PUT /api/users/me/preferences`

Save user preferences. Full replace (not partial update).

```
Request:
{
  "default_video_platform": "zoom",
  "default_session_type": "individual",
  "default_duration_minutes": 50,
  "auto_transcribe": true,
  "quality_preset": "balanced",
  "therapist_display_name": "Dr. Lee"
}

Response 200: (same object echoed back)
```

---

## Error Format

All errors follow a consistent format:

```json
{
  "detail": "Human-readable error message",
  "error_code": "INVALID_STATUS_TRANSITION",   // optional machine-readable code
  "field": "status"                             // optional, for validation errors
}
```

HTTP status codes:
- `400` — validation error, bad request
- `401` — missing or expired token
- `403` — user lacks permission
- `404` — resource not found
- `409` — conflict (e.g., duplicate, already in target state)
- `500` — server error

---

## Implementation Priority

| Priority | Endpoints | Dependency |
|----------|-----------|------------|
| 1 | Session model extension + `POST /schedule` + `GET /today` + `PATCH /status` | Unblocks companion day view |
| 2 | `POST /sessions/{id}/transcript` | Unblocks companion transcript upload |
| 3 | `PATCH /sessions/{id}` metadata update | Unblocks reschedule |
| 4 | User preferences endpoints | Unblocks settings sync |

---

## Companion Client Architecture

All backend communication routes through `core/src/api_client.rs` (Rust), exposed to Swift via UniFFI.

### FFI Pattern

Every API function accepts `base_url` and `token` as parameters. Rust never stores tokens — they stay in platform-native secure storage (Keychain) until call time.

```rust
// Rust (core/src/api_client.rs)
pub async fn fetch_today_sessions(
    base_url: String,
    token: String,
    timezone: String,
) -> Result<Vec<Session>, PabloError> { ... }
```

```swift
// Swift calls via UniFFI-generated function
let sessions = try await fetchTodaySessions(
    baseUrl: backendURL,
    token: authVM.getValidToken(),
    timezone: TimeZone.current.identifier
)
```

### Existing Swift Methods to Port to Rust

| Swift method | Rust equivalent |
|-------------|-----------------|
| `APIClient.healthCheck()` | `health_check(base_url)` |
| `APIClient.fetchPatients()` | `fetch_patients(base_url, token, search, page, page_size)` |
| `APIClient.uploadRecording()` | `upload_recording(base_url, token, file_path)` |

### New Rust API Methods

| Function | Endpoint |
|----------|----------|
| `fetch_today_sessions()` | `GET /api/sessions/today` |
| `create_session()` | `POST /api/sessions/schedule` |
| `update_session_status()` | `PATCH /api/sessions/{id}/status` |
| `update_session()` | `PATCH /api/sessions/{id}` |
| `upload_transcript()` | `POST /api/sessions/{id}/transcript` |
| `fetch_session()` | `GET /api/sessions/{id}` |
| `fetch_sessions()` | `GET /api/sessions` |
| `finalize_session()` | `PATCH /api/sessions/{id}/finalize` |
| `create_patient()` | `POST /api/patients` |
| `fetch_preferences()` | `GET /api/users/me/preferences` |
| `save_preferences()` | `PUT /api/users/me/preferences` |
| `fetch_user()` | `GET /api/users/me` |
| `check_baa_status()` | `GET /api/users/me/baa-status` |
| `accept_baa()` | `POST /api/users/me/accept-baa` |

---

## Backwards Compatibility

- Existing `POST /api/patients/{pid}/sessions/upload` remains unchanged
- Existing `POST /api/recordings/upload` remains unchanged
- New session fields (`scheduled_at`, `video_link`, etc.) are nullable — existing sessions without them continue to work
- New status values (`scheduled`, `in_progress`, `recording_complete`, `cancelled`) extend the enum — existing statuses unchanged
