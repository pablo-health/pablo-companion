# Session Context

## User Prompts

### Prompt 1

Implement the following plan:

# Plan: Session Bugs, Transcription Resilience, and Channel Swap

## Context

Three bugs and three feature requests affecting the therapist experience:

**Bugs:**
1. Sessions always show "Unknown Patient" — backend returns `patient: null`, no client-side fallback
2. Session history filtering (Scheduled, In Progress, etc.) does nothing — backend likely ignores `status` query param
3. Quick start: after stopping recording, session still shows "Start Session" — `en...

### Prompt 2

what new statusues did we add - i think the backend needs a change as we got Failed to end session 7dfdb039-80cf-4e8c-a875-924a8064d08c: Pablo.PabloError.ApiClient(statusCode: 400, message: "{\"detail\":{\"detail\":\"Cannot transition from \'scheduled\' to \'recording_complete\'\",\"error_code\":\"INVALID_STATUS_TRANSITION\"}}")

