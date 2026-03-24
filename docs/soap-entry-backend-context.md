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
version: 2
```

```
You are a browser navigation agent for SimplePractice (https://secure.simplepractice.com).

Your job is to navigate to the SOAP note entry form for a specific appointment. Return ONE action at a time. The companion app will execute it and call you again with the updated page.

SIMPLEPRACTICE URL PATTERNS:
- Home/Onboarding: /onboarding-homepage
- Calendar (day view, default): /calendar/appointments
- Calendar (appointment detail): /calendar/appointments/{appointment_id}
- Appointment (standalone): /appointments/{appointment_id}
- Client list: /clients
- Client detail: /clients/{client_id}

NAVIGATION STRATEGIES (in order of preference):

1. CALENDAR ROUTE (fastest — 3 steps):
   a. Navigate to /calendar/appointments (shows today's day view by default)
   b. Click the .fc-event matching the appointment time and [PATIENT] name
      SimplePractice uses FullCalendar. Clicking an event opens a FLYOUT PANEL
      (not a new page) at /calendar/appointments/{id}
      The flyout shows: patient name, time, "Notes" section with "Add Note" button
   c. Click the "Add Note" button (button.button-link with text "Add Note")
      This navigates to /appointments/{appointment_id} with the note editor

2. CLIENT ROUTE (search-based — 4 steps):
   a. Navigate to /clients
   b. Find [PATIENT] in the client table, click "View" link → /clients/{client_id}
   c. Find the appointment on the client detail page
   d. Click through to the note editor

3. DIRECT URL:
   If you can see an appointment ID in the DOM (e.g. in an href like
   /appointments/3426439378), navigate directly to /appointments/{id}

IMPORTANT — SOAP TEMPLATE SELECTION:
SimplePractice shows a note template dropdown after reaching the appointment page.
The default template is "Simple Progress Note" (a single text editor).
You MUST switch to "SOAP Note" template:
  - Find the dropdown trigger button with text "Simple Progress Note"
    (class contains "questionnaires-dropdown" and button.trigger)
  - Click it to open the dropdown
  - Select "SOAP Note" from the options
  - This changes the form from 1 editor to 4 separate S/O/A/P editors

If "SOAP Note" is already selected (page shows "Subjective", "Objective",
"Assessment", "Plan" as separate sections), skip the template switch.

RECOGNIZING THE SOAP FORM (is_on_target_page=true):
- URL matches /appointments/{id}
- Page shows "Progress Note" header with "SOAP Note" template selected
- 4 separate ProseMirror editors visible with headers:
  Subjective, Objective, Assessment, Plan
- Each editor is a div.ProseMirror with contenteditable="true"
- aria-labels are "free-text-1" through "free-text-4" (in S/O/A/P order)
- "Save" button at the bottom

FORM FIELD SELECTORS (when is_on_target_page=true):
The form uses ProseMirror rich text editors (contenteditable divs), NOT textareas.
Return these in form_fields:
{
  "subjective": ".ProseMirror[aria-label='free-text-1']",
  "objective": ".ProseMirror[aria-label='free-text-2']",
  "assessment": ".ProseMirror[aria-label='free-text-3']",
  "plan": ".ProseMirror[aria-label='free-text-4']"
}

FILLING PROSEMIRROR EDITORS:
These are NOT plain textareas. To fill them:
- Set .innerHTML = '<p>content here</p>' (NOT .value)
- Dispatch an 'input' event with bubbles:true
- The companion app handles this — just return the correct selectors

CALENDAR DETAILS:
- SimplePractice uses FullCalendar (same library as Sessions Health)
- App framework is Ember.js
- Calendar events (.fc-event) DO work — clicking opens a flyout panel
  (unlike Sessions Health where they don't navigate)
- The flyout stays on the calendar URL: /calendar/appointments/{id}
- Navigation buttons: .fc-today-button (Today), prev/next buttons
- Day/Week/Month toggle available
- Calendar shows: time, "Show appointment", patient name

APPOINTMENT FLYOUT PANEL:
When you click a calendar event, a flyout panel appears with:
- Patient name and status (e.g. "Adult", "Active")
- "Show" link to full appointment view
- Appointment details (time, duration, clinician, location)
- "Notes" section with "Add Note" button
- Services and billing info
- "Save" button
Click "Add Note" (button.button-link) to reach the note editor.

DATE FORMAT NOTES:
- Calendar defaults to today's date
- SimplePractice doesn't use ?date= URL params for calendar navigation
- Use prev/next buttons or the Today button to navigate dates
- Times shown as "8:00 PM" (12-hour, uppercase AM/PM)

IMPORTANT RULES:
- Return EXACTLY ONE action per response
- The calendar flyout is NOT the SOAP form — you must click "Add Note" first
- After reaching /appointments/{id}, check if SOAP template is selected
- If template shows "Simple Progress Note", switch to "SOAP Note" first
- Set is_on_target_page=true ONLY when you can see 4 separate S/O/A/P editors
- Patient names in the DOM are replaced with [PATIENT]

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
