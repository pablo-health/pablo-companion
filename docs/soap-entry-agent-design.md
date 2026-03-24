# SOAP Entry Agent: Navigation & Workflow Design

## Sessions Health Route Map (discovered via CDP exploration)

### URL Patterns
```
Home:           /
Calendar week:  /calendar?view=week
Calendar day:   /calendar?date=2026-03-23&view=day
Calendar date:  /calendar?date=2026-03-23
Client list:    /clients
Client detail:  /clients/{client_id}
Client details: /clients/{client_id}/details
Event (SOAP):   /events/{event_id}-{YYMMDD}
Event (todo):   /events/{event_id}-{YYMMDD}?source=todo
```

### Route 1: Home Dashboard (fastest, when available)

**When it works:** Today's appointments appear on the home dashboard.

```
/ (Home)
  → Find <a href="/events/{id}-{date}"> where adjacent text matches patient name + today's time
  → Click → lands on /events/{id} with SOAP form
```

**DOM pattern:**
```html
<a class="ember-view text-dark" href="/events/21581112-260323">Pablo Bear</a>
<!-- Adjacent: "8:00pm - 8:30pm" -->
```

**Also:** Incomplete Notes section at bottom has direct links with `?source=todo`.

### Route 2: Calendar → Date → Event (reliable, always works)

**When to use:** Appointment not on home dashboard, or date is not today.

```
/calendar?date={YYYY-MM-DD}&view=day
  → Renders FullCalendar day view with the target date
  → Find .fc-event containing patient name + time
  → Calendar events use Ember routing (not <a href>)
  → Need to extract event URL from the Ember data or navigate via the
    Incomplete Notes sidebar (which IS present on calendar page too)
```

**Key discovery:** Calendar events (`.fc-event`) don't have `href` attributes. Clicking them doesn't navigate — they use Ember's internal routing. However:
- The calendar page also shows the "Incomplete Notes" sidebar with direct `<a>` links
- We can use `/calendar?date=YYYY-MM-DD` URL params to jump to any date
- **Best approach:** Navigate to `/calendar?date={date}` then look for the event link in the sidebar, OR extract the event ID from the `.fc-event` data attributes

**Navigation controls:**
- `button[aria-label="Previous"]` (.calendar-nav-btn) — go back one week/day
- `button[aria-label="Next"]` (.calendar-nav-btn) — go forward
- `.calendar-today-btn` — jump to today
- URL param `?date=YYYY-MM-DD` — jump to any date directly (best option)
- URL param `?view=day` or `?view=week` — switch views

### Route 3: Clients → Patient → Event (search-based)

**When to use:** Don't know the date, or need to find a specific patient.

```
/clients
  → Table with columns: Name, Next Appointment
  → Find row where Name matches patient
  → Click "View" link → /clients/{client_id}
  → Client detail page shows Notes section with all appointments
  → Find appointment matching date → <a href="/events/{id}-{date}">
  → Click → SOAP form
```

**DOM patterns:**
```
Clients page:  <a href="/clients/2661756">View</a>  (in table row with "Pablo Bear")
Client detail: <a href="/events/21581112-260323">23 Mar</a>  (in Notes section)
               <a href="/events/21581112-260323">Appointment</a>
               <a href="/events/21581112-260323">Incomplete</a>
```

### SOAP Form (all routes lead here)

**URL:** `/events/{event_id}-{YYMMDD}`

**Form fields (Sessions Health SOAP template):**
```
textarea#ember66-input  → Subjective *
textarea#ember67-input  → Objective *
textarea#ember68-input  → Assessment *
textarea#ember69-input  → Plan *
```

Note: Ember IDs (`ember66`, `ember67`, etc.) are **not stable** — they change between sessions. Must identify fields by position (4 consecutive `textarea.expanding-textarea` elements in the Notes section) or by nearby label text.

**Submit:** "Sign and Complete" button at bottom of form.

**Additional form elements:**
- "Add to note" dropdown
- Attachment upload
- Medications
- Mental Status Exam
- Diagnosis section
- Treatment Plan section

---

## Agent Workflow Design

### Core Principle: Goal-Driven, Not Script-Driven

The agent doesn't follow a fixed sequence of intents. Instead, it has a **goal** and the LLM decides the best path based on what it sees on the current page.

### State Machine

```
┌──────────┐
│  START   │
└────┬─────┘
     ▼
┌──────────────────┐     route found
│ Try cached route │────────────────────┐
└────┬─────────────┘                    │
     │ no route / route failed          │
     ▼                                  ▼
┌──────────────────┐         ┌──────────────────┐
│ LLM: Plan route  │         │ Execute cached   │
│ (send DOM, goal) │         │ steps             │
└────┬─────────────┘         └────┬─────────────┘
     │                            │ step failed
     │                            ▼
     │                   ┌──────────────────┐
     │                   │ LLM: Fix step    │
     │                   │ (send DOM, error)│
     │                   └────┬─────────────┘
     │                        │
     ▼                        ▼
┌──────────────────────────────────────┐
│ ON SOAP FORM: Verify patient + time  │
│ (deterministic text match, no LLM)   │
└────┬─────────────────────────────────┘
     │
     ▼
┌──────────────────────────────────────┐
│ AWAIT CONFIRMATION                   │
│ Show therapist: patient, time, form  │
│ [Confirm] [Cancel]                   │
└────┬──────────────┬──────────────────┘
     │ confirm      │ cancel
     ▼              ▼
┌─────────────┐  ┌───────────┐
│ Fill S/O/A/P│  │ CANCELLED │
│ via CDP     │  └───────────┘
└────┬────────┘
     ▼
┌──────────────────────────────────────┐
│ DONE — note entered, NOT submitted   │
│ Therapist clicks "Sign and Complete" │
│ themselves (safety)                  │
└──────────────────────────────────────┘
```

### Backend API: Goal-Based Navigation

**Replace the rigid intent enum with a single goal-based endpoint.**

#### `POST /api/ehr-navigate`

```json
{
  "ehr_system": "sessions_health",
  "goal": "Navigate to the SOAP note form for the appointment on 2026-03-23 at 8:00 PM",
  "current_url": "https://app.sessionshealth.com/",
  "dom_snapshot": "<body>...(stripped of PHI)...</body>",
  "previous_actions": [
    {"action": "navigate", "target": "/", "result": "success"}
  ],
  "failed_action": null
}
```

**Response:**
```json
{
  "action": "click",
  "selector": "a[href*='/events/'][href*='260323']",
  "reasoning": "Found direct link to March 23 event on home dashboard",
  "confidence": 0.95,
  "is_on_target_page": false,
  "alternative_plan": "If link not found, navigate to /calendar?date=2026-03-23&view=day"
}
```

**Or if no direct link exists:**
```json
{
  "action": "navigate",
  "selector": "/calendar?date=2026-03-23&view=day",
  "reasoning": "No matching event on home page. Navigating to calendar day view for March 23.",
  "confidence": 0.90,
  "is_on_target_page": false,
  "alternative_plan": "If calendar doesn't show event, try /clients route"
}
```

**When on the SOAP form:**
```json
{
  "action": "none",
  "selector": "",
  "reasoning": "Already on SOAP form for Pablo Bear's 8:00 PM appointment",
  "confidence": 0.98,
  "is_on_target_page": true,
  "form_fields": {
    "subjective": "textarea:nth-of-type(1)",
    "objective": "textarea:nth-of-type(2)",
    "assessment": "textarea:nth-of-type(3)",
    "plan": "textarea:nth-of-type(4)"
  }
}
```

### LLM Prompt (constructed server-side)

```
You are a browser navigation agent for the EHR system "sessions_health" (Sessions Health).

GOAL: {goal}

CURRENT PAGE URL: {current_url}

KNOWN ROUTES for Sessions Health:
1. Home (/) — shows today's upcoming appointments with direct links to events
2. Calendar (/calendar?date=YYYY-MM-DD&view=day) — shows all appointments for a date
3. Clients (/clients) → Client detail (/clients/{id}) — shows all appointments for a patient
4. Direct event URL: /events/{event_id}-{YYMMDD} — goes straight to SOAP form

PREVIOUS ACTIONS THIS SESSION: {previous_actions}

CURRENT PAGE DOM (interactive elements):
{dom_snapshot}

RULES:
- Return ONE action to take next
- Prefer the shortest path (direct link > calendar > client search)
- If you see a direct <a href="/events/..."> link matching the date, click it
- Calendar ?date= URL param lets you jump to any date without clicking prev/next
- SOAP form has 4 consecutive <textarea> elements: Subjective, Objective, Assessment, Plan
- Ember element IDs (ember66, ember67) are NOT stable — use position or label proximity
- If you're already on the target page, set is_on_target_page=true

Return JSON only:
{
  "action": "click" | "navigate" | "wait" | "none",
  "selector": "CSS selector or URL path",
  "reasoning": "brief explanation",
  "confidence": 0.0-1.0,
  "is_on_target_page": boolean,
  "form_fields": null | {"subjective": "...", "objective": "...", "assessment": "...", "plan": "..."},
  "alternative_plan": "what to try if this action fails"
}
```

### Security Model

```
Client (Swift)                        Backend (Python/FastAPI)
─────────────────                     ──────────────────────────
1. Reads DOM via CDP
2. Strips ALL patient names
   from DOM snapshot
3. Sends goal + stripped DOM    ────► 4. Validates request schema
                                      5. Rate limit (50/user/day)
                                      6. Constructs LLM prompt
                                         (client CANNOT send prompts)
                                      7. Calls Gemini 2.5 Flash-Lite
                                      8. Validates LLM response shape
                                ◄──── 9. Returns {action, selector}
10. Executes action via CDP
11. Repeats until on target page
12. Verifies patient name locally
    (text match, NO LLM)
13. Shows confirmation to therapist
14. On confirm: fills fields via CDP
```

**PHI never reaches the LLM.** The goal says "appointment on 2026-03-23 at 8:00 PM" — no patient name. Patient verification happens client-side via deterministic text matching in the DOM.

### Orchestration Loop (Swift client)

```swift
func navigateToSoapForm(input: SoapEntryInput) async throws -> SoapEntryConfirmation {
    let cdp = try await connectToChrome(ehrSystem: input.ehrSystem)
    var previousActions: [PreviousAction] = []
    let maxSteps = 10  // safety limit

    for step in 0..<maxSteps {
        let currentURL = try await cdp.evaluateJS("window.location.href")
        let domSnapshot = try await getDOMSnapshot(cdp: cdp, patientName: input.patientName)

        // Ask LLM what to do
        let response = try await apiClient.navigate(
            ehrSystem: input.ehrSystem,
            goal: "Navigate to SOAP note form for appointment on \(input.appointmentTime)",
            currentURL: currentURL,
            domSnapshot: domSnapshot,
            previousActions: previousActions,
            failedAction: nil
        )

        // Are we on the target page?
        if response.isOnTargetPage {
            // Verify patient + time via local text match
            let pageText = try await cdp.evaluateJS("document.body.innerText")
            let patientMatch = try findPatientMatch(in: pageText, name: input.patientName)
            let timeMatch = try findAppointmentMatch(in: pageText, time: input.appointmentTime)
            return SoapEntryConfirmation(
                patientMatch: patientMatch,
                appointmentMatch: timeMatch,
                formFields: response.formFields,
                ...
            )
        }

        // Execute the action
        try await executeAction(response.action, selector: response.selector, cdp: cdp)
        previousActions.append(PreviousAction(action: response.action, target: response.selector, result: "success"))

        // Wait for page to settle
        try await Task.sleep(for: .milliseconds(800))
    }

    throw EHRNavigatorError.maxStepsExceeded
}
```

### Route Caching (v2)

Instead of caching a rigid step sequence, cache **successful action traces**:

```json
{
  "ehr_system": "sessions_health",
  "traces": [
    {
      "scenario": "appointment_on_home_dashboard",
      "steps": [
        {"url_pattern": "/$", "action": "click", "selector": "a[href*='/events/'][href*='{date_compact}']"}
      ],
      "success_count": 142,
      "last_success": "2026-03-23T20:15:00Z"
    },
    {
      "scenario": "appointment_via_calendar",
      "steps": [
        {"url_pattern": ".*", "action": "navigate", "selector": "/calendar?date={date}&view=day"},
        {"url_pattern": "/calendar", "action": "click", "selector": "a[href*='/events/'][href*='{date_compact}']"}
      ],
      "success_count": 38,
      "last_success": "2026-03-22T16:00:00Z"
    },
    {
      "scenario": "appointment_via_client",
      "steps": [
        {"url_pattern": ".*", "action": "navigate", "selector": "/clients"},
        {"url_pattern": "/clients$", "action": "click", "selector": "tr:has(td:contains('{patient_name}')) a"},
        {"url_pattern": "/clients/\\d+", "action": "click", "selector": "a[href*='/events/'][href*='{date_compact}']"}
      ],
      "success_count": 12,
      "last_success": "2026-03-20T09:30:00Z"
    }
  ]
}
```

The client tries traces in order of `success_count` (most reliable first). If a trace fails, it falls through to the LLM. Successful LLM navigations create new traces.

### Form Field Identification

Ember IDs are unstable. Use this pattern to identify SOAP fields:

```javascript
// Find the 4 SOAP textareas by their position in the form
const textareas = document.querySelectorAll('textarea.expanding-textarea.form-control');
// textareas[0] = Subjective, [1] = Objective, [2] = Assessment, [3] = Plan
```

Or by label proximity:
```javascript
// Find textarea whose preceding label/header contains "Subjective"
const labels = document.querySelectorAll('label, .form-label, h5, h6');
for (const label of labels) {
    if (label.innerText.includes('Subjective')) {
        const textarea = label.closest('.form-group')?.querySelector('textarea');
    }
}
```

Both approaches should be tried — the LLM can figure out which pattern matches the current page layout.
