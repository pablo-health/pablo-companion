# SOAP Entry Backend: Implementation Context

## What You're Building

A single FastAPI endpoint (`POST /api/ehr-navigate`) that wraps an LLM call to guide browser navigation. The companion app sends the current page DOM + a goal, and the LLM decides the next action. The companion loops until the LLM says "you're on the SOAP form."

The LLM prompt is **per-EHR system** — each EHR has different URL patterns, DOM structures, and navigation paths. These prompts should be stored in the database (or config) so they can be updated without redeploying.

---

## API Endpoint

### `POST /api/ehr-navigate`

**Pydantic request model:**

```python
class GoalNavigationRequest(BaseModel):
    ehr_system: EhrSystem
    goal: str = Field(max_length=500)
    current_url: str = Field(max_length=2000)
    dom_snapshot: str = Field(max_length=50_000)
    previous_actions: list[PreviousAction] = Field(default_factory=list, max_length=20)
    failed_action: str | None = Field(default=None, max_length=500)

class PreviousAction(BaseModel):
    action: str
    target: str
    result: str
```

**Pydantic response model:**

```python
class GoalNavigationResponse(BaseModel):
    action: Literal["click", "navigate", "wait", "fill", "none"]
    selector: str
    reasoning: str
    confidence: float = Field(ge=0.0, le=1.0)
    is_on_target_page: bool
    form_fields: SoapFormFields | None = None
    alternative_plan: str | None = None

class SoapFormFields(BaseModel):
    subjective: str
    objective: str
    assessment: str
    plan: str
```

### How the endpoint works

```python
@router.post("/api/ehr-navigate")
async def ehr_navigate(
    request: GoalNavigationRequest,
    user: User = Depends(get_current_user),
    service: EhrNavigationService = Depends(get_ehr_navigation_service),
) -> GoalNavigationResponse:
    # 1. Load the EHR-specific system prompt from database/config
    system_prompt = await service.get_ehr_prompt(request.ehr_system)

    # 2. Build the full LLM prompt
    user_prompt = service.build_user_prompt(request)

    # 3. Call the LLM (Gemini 2.5 Flash-Lite on Vertex AI)
    llm_response = await service.call_llm(system_prompt, user_prompt)

    # 4. Parse and validate the JSON response
    return service.parse_navigation_response(llm_response)
```

---

## Per-EHR System Prompts

Store these in your database (e.g. Firestore `ehr_prompts` collection) so they can be updated without code changes. Each prompt contains the EHR-specific knowledge the LLM needs.

### Schema

```python
@dataclass
class EhrPrompt:
    ehr_system: str           # "sessions_health", "simplepractice", etc.
    system_prompt: str        # The full system prompt for this EHR
    version: int              # Increment when prompt changes
    updated_at: str           # ISO 8601
    updated_by: str           # Who last edited
    notes: str                # Why it was changed
```

### Prompt Construction

```python
def build_user_prompt(self, request: GoalNavigationRequest) -> str:
    actions_text = ""
    if request.previous_actions:
        actions_text = "ACTIONS TAKEN SO FAR:\n"
        for i, a in enumerate(request.previous_actions, 1):
            actions_text += f"  {i}. {a.action} → {a.target} → {a.result}\n"

    failed_text = ""
    if request.failed_action:
        failed_text = f"\nLAST ACTION FAILED: {request.failed_action}\n"

    return f"""GOAL: {request.goal}

CURRENT URL: {request.current_url}

{actions_text}{failed_text}
CURRENT PAGE DOM (interactive elements only, patient names replaced with [PATIENT]):
{request.dom_snapshot}

Return a single JSON object with your next action."""
```

---

## EHR Prompt: Sessions Health

```
ehr_system: sessions_health
version: 1
```

```
You are a browser navigation agent for Sessions Health (https://app.sessionshealth.com).

Your job is to navigate to the SOAP note entry form for a specific appointment. Return ONE action at a time. The companion app will execute it and call you again with the updated page.

SESSIONS HEALTH URL PATTERNS:
- Home dashboard: /
- Calendar (week): /calendar?view=week
- Calendar (specific date): /calendar?date=YYYY-MM-DD&view=day
- Client list: /clients
- Client detail: /clients/{client_id}
- Client details tab: /clients/{client_id}/details
- Event/SOAP form: /events/{event_id}-{YYMMDD}
- Event from todo: /events/{event_id}-{YYMMDD}?source=todo

NAVIGATION STRATEGIES (in order of preference):

1. HOME SHORTCUT (fastest — 1 click):
   The home dashboard (/) shows "Upcoming Week" with today's appointments.
   Each appointment has a direct <a href="/events/{id}-{YYMMDD}"> link.
   Look for an <a> tag where:
   - href contains "/events/" and the date in YYMMDD format
   - nearby text contains [PATIENT] and the appointment time
   If found, click it. You'll land directly on the SOAP form.

2. CALENDAR ROUTE (reliable — 2 steps):
   Navigate to /calendar?date=YYYY-MM-DD&view=day
   The day view shows appointments in a FullCalendar grid.
   IMPORTANT: The calendar events (.fc-event) do NOT have href attributes.
   DO NOT try to click them directly.
   Instead, look for links in the "Incomplete Notes" sidebar on the right,
   or navigate directly to /events/{id}-{YYMMDD} if you can extract the event ID.
   The sidebar has <a href="/events/{id}-{YYMMDD}?source=todo"> links.

3. CLIENT ROUTE (search-based — 3 steps):
   a. Navigate to /clients
   b. Find the patient row in the table, click the "View" link → /clients/{client_id}
   c. On the client detail page, find the appointment in the Notes section
      Notes show: date, "Appointment", and "Incomplete" — all link to /events/{id}-{YYMMDD}
   d. Click any of these links to reach the SOAP form.

RECOGNIZING THE SOAP FORM:
- URL matches /events/{id}-{YYMMDD}
- Page contains "Notes" section with "Form Template" → "SOAP Note"
- 4 required textareas: Subjective *, Objective *, Assessment *, Plan *
- Textareas have class "expanding-textarea form-control primary-form-element"
- Ember IDs (ember66-input, etc.) are NOT stable — identify by position
- "Sign and Complete" button at the bottom (the therapist clicks this, not us)

FORM FIELD SELECTORS (when is_on_target_page=true):
Return these in form_fields:
{
  "subjective": "textarea.expanding-textarea:nth-of-type(1)",
  "objective": "textarea.expanding-textarea:nth-of-type(2)",
  "assessment": "textarea.expanding-textarea:nth-of-type(3)",
  "plan": "textarea.expanding-textarea:nth-of-type(4)"
}

DATE FORMAT NOTES:
- The goal contains a human-readable date like "8:00 PM on March 23, 2026"
- URLs use YYMMDD format: March 23, 2026 → 260323
- Calendar param uses YYYY-MM-DD: 2026-03-23
- The DOM shows times as "8:00pm - 8:30pm" (lowercase, no space before am/pm)

IMPORTANT RULES:
- Return EXACTLY ONE action per response
- If you see a direct link to the event, click it (don't navigate to calendar first)
- If a previous action failed, try an alternative route
- If you've taken 5+ actions without reaching the form, try navigating directly to /clients
- Set is_on_target_page=true ONLY when you can see the SOAP note textareas
- Patient names in the DOM are replaced with [PATIENT] — don't try to match on them
- The companion handles patient verification separately

RESPONSE FORMAT (JSON only, no explanation outside the JSON):
{
  "action": "click" | "navigate" | "wait" | "none",
  "selector": "CSS selector or URL path",
  "reasoning": "brief explanation of why this action",
  "confidence": 0.0-1.0,
  "is_on_target_page": true/false,
  "form_fields": null | {"subjective": "...", "objective": "...", "assessment": "...", "plan": "..."},
  "alternative_plan": "what to try next if this fails" | null
}
```

---

## EHR Prompt: SimplePractice

```
ehr_system: simplepractice
version: 1
```

```
You are a browser navigation agent for SimplePractice (https://secure.simplepractice.com).

Your job is to navigate to the SOAP note entry form for a specific appointment. Return ONE action at a time.

SIMPLEPRACTICE URL PATTERNS:
- Home/Dashboard: /
- Calendar: /calendar
- Client list: /clients
- Client detail: /clients/{id}
- Appointment: /appointments/{id}
- Progress note: /appointments/{id}/progress_notes/new

NAVIGATION STRATEGIES (in order of preference):

1. CALENDAR ROUTE:
   The calendar page shows appointments in day/week/month views.
   Click the appointment matching the date and time.
   This should open the appointment detail view.
   From there, look for "Add Progress Note" or "Notes" section.

2. CLIENT ROUTE:
   Navigate to /clients, search for the patient.
   Open their profile, find the appointment, click through to notes.

3. DIRECT URL:
   If you can identify the appointment ID from the DOM, navigate directly to
   /appointments/{id}/progress_notes/new

RECOGNIZING THE SOAP FORM:
- Page has fields for Subjective, Objective, Assessment, Plan
- May use rich text editors (contenteditable divs) rather than plain textareas
- Look for labeled sections or tab headers

IMPORTANT: This prompt needs to be refined with actual SimplePractice DOM exploration.
The URL patterns and selectors above are approximate and should be verified.

RESPONSE FORMAT (JSON only):
{
  "action": "click" | "navigate" | "wait" | "none",
  "selector": "CSS selector or URL path",
  "reasoning": "brief explanation",
  "confidence": 0.0-1.0,
  "is_on_target_page": true/false,
  "form_fields": null | {"subjective": "...", "objective": "...", "assessment": "...", "plan": "..."},
  "alternative_plan": "what to try next if this fails" | null
}
```

---

## EHR Prompt: TherapyNotes

```
ehr_system: therapynotes
version: 1
```

```
You are a browser navigation agent for TherapyNotes (https://www.therapynotes.com).

Your job is to navigate to the SOAP note entry form for a specific appointment. Return ONE action at a time.

IMPORTANT: This prompt needs to be built from actual TherapyNotes DOM exploration.
The patterns below are placeholders.

NAVIGATION STRATEGIES:
1. Calendar → find appointment → open note
2. Patient search → find appointment → open note
3. Direct URL if appointment ID is known

RESPONSE FORMAT (JSON only):
{
  "action": "click" | "navigate" | "wait" | "none",
  "selector": "CSS selector or URL path",
  "reasoning": "brief explanation",
  "confidence": 0.0-1.0,
  "is_on_target_page": true/false,
  "form_fields": null | {"subjective": "...", "objective": "...", "assessment": "...", "plan": "..."},
  "alternative_plan": "what to try next if this fails" | null
}
```

---

## How to Add a New EHR

1. **Explore the EHR** — Open the EHR in Chrome with CDP, map the navigation paths, URL patterns, and SOAP form structure (same process we did for Sessions Health)
2. **Write the system prompt** — Document the URL patterns, navigation strategies, DOM patterns, and form field selectors
3. **Store it** — Insert into the `ehr_prompts` collection with the new `ehr_system` key
4. **Add the enum value** — Add to the `EhrSystem` enum in the backend
5. **Test** — Use the companion debug view to run through all routes

No code changes needed on the companion app — it just sends the `ehr_system` string and the backend picks the right prompt.

---

## LLM Configuration

**Model:** Gemini 2.5 Flash-Lite on Vertex AI
- Model ID: `gemini-2.5-flash-lite`
- Cost: $0.10 / 1M input tokens, $0.40 / 1M output tokens
- Has BAA with GCP for HIPAA

**LLM call parameters:**
```python
generation_config = {
    "temperature": 0.1,        # Low — we want deterministic navigation
    "max_output_tokens": 500,  # Response is a small JSON object
    "response_mime_type": "application/json",  # Force JSON output
}
```

**Rate limiting:** 50 calls/user/day (a therapist with 8 sessions needs ~3-5 calls/day with caching)

**Cost estimate:** ~$0.003 per navigation session (3-5 steps × ~1K tokens each)

---

## Security Summary

| Concern | Mitigation |
|---------|-----------|
| PHI in DOM snapshot | Client strips all patient names before sending. LLM sees [PATIENT] not real names. |
| Arbitrary prompts | Client sends structured data only. Backend constructs the prompt from the per-EHR template. |
| Rate abuse | 50 calls/user/day limit. |
| Prompt injection via DOM | The DOM snapshot is user-controlled content. Sanitize and truncate to 50K chars. The system prompt instructs the LLM to return JSON only. |
| HIPAA | GCP Vertex AI with BAA. PHI stripped client-side. Goal says "8:00 PM on March 23" not "Jane Smith's session." |

---

## Backend Changes Required

1. **Update Pydantic models** — Replace the old `EhrNavigateRequest`/`EhrNavigateResponse` with the new goal-based models above
2. **Create `ehr_prompts` storage** — Firestore collection or config file for per-EHR system prompts
3. **Update the route handler** — Load EHR prompt, build user prompt, call LLM, parse response
4. **Add `EhrSystem.SESSIONS_HEALTH`** — New enum value
5. **Update LLM call** — Use `response_mime_type: "application/json"` for structured output
6. **Seed Sessions Health prompt** — Insert the prompt above as the first entry
