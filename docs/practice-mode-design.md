# Practice Mode — Design Document

_Created: 2026-03-31_
_Status: DRAFT — awaiting review_

---

## 1. What Is Practice Mode?

A built-in training/demo feature where a therapist conducts a simulated therapy session with **Pablo Bear as an AI patient**. The therapist speaks naturally, Pablo responds with AI-generated speech, and the entire session flows through the real Pablo pipeline — producing a SOAP note at the end.

### Why Build This?

| Use case | Value |
|----------|-------|
| **Therapist onboarding** | New users experience the full record → transcribe → SOAP flow without needing a real patient |
| **Sales demos** | Show the complete product in 5 minutes without staging a real session |
| **QA / regression testing** | Automated or semi-automated end-to-end pipeline validation |
| **Therapist training** | Practice with different presenting issues (anxiety, depression, couples conflict, etc.) |

### What It Is NOT

- Not a replacement for real clinical sessions
- Not a clinical training tool (no CEU credits, no clinical validity claims)
- Not a chatbot product — this is an internal feature of the companion app

---

## 2. Competitive Landscape

**No competitor in the therapy note-taking space offers anything like this.**

### How Competitors Handle Onboarding Today

| Competitor | Onboarding approach | Interactive? |
|------------|-------------------|-------------|
| **Mentalyc** | Free trial, upload a recording, sample notes on website | No |
| **Eleos Health** | Sales-led demo, white papers | No |
| **Freed** | Free trial, record a real patient session, sample note on website | No |
| **Upheal** | Free tier, upload a recording, sample analytics | No |
| **Blueprint Health** | Sales-led demo, pilot programs | No |
| **Lyssn** | Academic/enterprise sales, research papers | No |
| **SimplePractice** | 30-day free trial (AI notes on real sessions) | No |

Every competitor has the same cold-start problem: therapists must either watch a demo, read sample output, or risk trying the product on a real patient. Nobody lets you **experience the full pipeline without a real patient.**

### Why This Matters

- **Therapists are risk-averse.** The patient relationship is sacred. Asking them to try new recording software on a real session is a big ask.
- **The "aha moment" is the SOAP note.** But today, getting to that moment requires a real session first. Practice mode collapses this to minutes.
- **Sales demos are static.** A live, interactive session where the therapist actually practices their craft and sees *their own* SOAP note is fundamentally different from watching a pre-recorded demo.

### The Marketing Angle

> **"See your first SOAP note in 3 minutes — no real patient needed."**

No competitor can match this CTA today. Practice mode turns onboarding from "trust us, it works" into "try it yourself, right now."

### Adjacent Validation

AI-simulated patients are well-established in medical education (OSCE training, standardized patient simulations). The concept works. The innovation is applying it as a product experience, not clinical training.

---

## 3. User Experience

### Flow

```
1. Therapist clicks "Practice Session" from day view (or menu)
2. Picks a topic: "Generalized Anxiety", "Grief & Loss", "Couples Conflict", etc.
3. Practice Session window opens:
   ┌─────────────────────────────────────┐
   │         🐻 Pablo Bear               │
   │      [static illustration]          │
   │                                     │
   │   ~~~~ speaking waveform ~~~~       │
   │                                     │
   │  Topic: Generalized Anxiety         │
   │  Duration: 3:42                     │
   │                                     │
   │  [ Pause ]  [ End Session ]         │
   └─────────────────────────────────────┘
4. Therapist speaks → Pablo listens → Pablo responds with voice
5. Natural back-and-forth for 5-15 minutes
6. Therapist clicks "End Session"
7. Standard pipeline runs: transcribe → upload → SOAP note generated
8. Therapist sees their SOAP note — same UI as a real session
```

### Key UX Details

- Pablo's image is static (illustration from brand assets), with a subtle waveform or glow animation when "speaking"
- Session timer visible throughout
- Topic displayed so therapist remembers the scenario
- "End Session" triggers the same flow as ending a real session
- Practice sessions are visually tagged in session history (e.g., "Practice" badge)

---

## 4. Architecture

### High-Level Flow

```
┌──────────────────────────────────────┐     ┌──────────────────────────────┐
│  Pablo Companion (macOS or Windows)  │     │  Pablo Backend (GCP)         │
│                                      │     │                              │
│  ┌──────────────┐  ┌──────────────┐  │     │  ┌────────────────────────┐  │
│  │ Practice     │  │ Audio Capture│  │     │  │ Practice Session       │  │
│  │ Session UI   │  │ (existing)   │  │     │  │ Orchestrator           │  │
│  │              │  │              │  │     │  │                        │  │
│  │ Pablo Bear   │  │ Mic ─→ ther.│  │     │  │  System prompts        │  │
│  │ + waveform   │  │ Sys ─→ cli. │  │     │  │  Topic catalog         │  │
│  └──────┬───────┘  └──────┬───────┘  │     │  │  Session state         │  │
│         │                 │          │     │  │  Usage tracking         │  │
│         ▼                 │          │     │  └──────────┬─────────────┘  │
│  ┌─────────────────────┐  │          │     │             │                │
│  │ Thin WebSocket      │  │          │     │             ▼                │
│  │ Client              │  │          │     │  ┌────────────────────────┐  │
│  │                     │  │          │     │  │ Gemini Live API        │  │
│  │ 1. Send mic PCM ────┼──┼──────────┼─────┼──▶ (same GCP region)     │  │
│  │                     │  │          │     │  │                        │  │
│  │ 2. Receive Pablo ◀──┼──┼──────────┼─────┼──│ audio in → audio out  │  │
│  │    audio chunks     │  │          │     │  │ built-in VAD + TTS    │  │
│  │                     │  │          │     │  └────────────────────────┘  │
│  │ 3. Play via ────────┼──┘          │     │                              │
│  │    AVAudioPlayer    │ (captured   │     └──────────────────────────────┘
│  │    (system audio)   │  as "client"│
│  └─────────────────────┘  channel)   │
│         │                            │
│         ▼  (on "End Session")        │
│  ┌────────────────────────────────┐  │
│  │ Existing Pipeline (unchanged)  │  │
│  │ transcribe → upload → SOAP     │  │
│  └────────────────────────────────┘  │
└──────────────────────────────────────┘
```

### The Key Trick: Audio Routing

The existing AudioCaptureKit setup captures **mic audio** (therapist) and **system audio** (everything else) as separate streams. If Pablo's TTS response plays through the system audio path (via `AVAudioPlayer` or `NSSound`), it gets captured automatically as the "client" channel.

**This means zero changes to the transcription pipeline.** The existing `transcribe_session_1on1()` labels mic as THERAPIST and system as CLIENT — which is exactly correct for practice mode.

### Components

| Component | Location | New vs. Existing | Notes |
|-----------|----------|-----------------|-------|
| **Backend** | | | |
| Practice session orchestrator | `backend/app/services/practice_service.py` | **New** | WebSocket hub: client ↔ Gemini Live, session state, usage tracking |
| Practice WebSocket endpoint | `backend/app/routes/practice_routes.py` | **New** | `ws://api/practice/session` — single endpoint for all clients |
| Topic catalog + system prompts | `backend/app/data/practice_topics/` | **New** | JSON files with topics and prompt templates, hot-reloadable |
| **Client (macOS)** | | | |
| Practice session window | `mac/Views/PracticeSessionView.swift` | **New** | Pablo Bear image, waveform, topic, timer, controls |
| Topic picker sheet | `mac/Views/PracticeTopicSheet.swift` | **New** | |
| Thin WebSocket client | `mac/Services/PracticeSessionClient.swift` | **New** | Sends mic PCM, receives Pablo audio, plays via AVAudioPlayer |
| Audio source protocol | `mac/Services/AudioSourceProtocol.swift` | **New** | Enables test injection for automated mode |
| **Client (Windows)** | | | |
| (Same WebSocket client + UI) | `windows/` | **Future** | Same WebSocket API — different native UI |
| **Existing (unchanged)** | | | |
| Audio capture | `mac/Services/RecordingService.swift` | Existing | Dual-stream: mic = therapist, system audio = Pablo |
| Transcription pipeline | `core/src/session_pipeline.rs` | Existing | |
| Session lifecycle API | `core/src/api_client.rs` | Existing | |
| SOAP note generation | Pablo backend | Existing | |

---

## 5. The Backend Question

### Session Pipeline: Same Pablo Backend

The whole point is to exercise the real pipeline. Practice sessions:
- Create a real `Session` object via `POST /api/sessions`
- Upload a real transcript via `POST /api/sessions/{id}/transcripts`
- Generate a real SOAP note through the existing backend pipeline
- Appear in session history (tagged as practice)

### Conversation Engine: Backend WebSocket Orchestrator on GCP

The conversation engine lives on the Pablo backend (GCP), not on the client. Both macOS and Windows clients connect to the same backend service via WebSocket. The backend manages the Gemini Live API connection server-side.

```
┌──────────────┐                ┌──────────────────────────────────────┐
│  macOS app   │                │  Pablo Backend (GCP)                 │
│              │   WebSocket    │                                      │
│  mic audio ──┼───────────────▶│  Practice Session Orchestrator       │
│              │                │                                      │
│  ◀───────────┼────────────────│    ┌────────────────────────────┐   │
│  speaker     │   audio chunks │    │  Gemini Live API           │   │
│  (system     │                │    │  (same GCP region)         │   │
│   audio)     │                │    │                            │   │
└──────────────┘                │    │  audio in → audio out      │   │
                                │    │  built-in VAD              │   │
┌──────────────┐                │    │  built-in TTS              │   │
│  Windows app │   WebSocket    │    └────────────────────────────┘   │
│              │───────────────▶│                                      │
│  (same API)  │◀───────────────│  Also manages:                      │
└──────────────┘                │  - System prompts / topic catalog    │
                                │  - Session state / turn history      │
                                │  - Usage tracking / rate limits      │
                                │  - Model selection (configurable)    │
                                └──────────────────────────────────────┘
```

**Why backend orchestrator instead of client-side:**

| Concern | Backend orchestrator | Client-side (rejected) |
|---------|---------------------|----------------------|
| Cross-platform parity | One implementation, both clients are thin audio pipes | Duplicate conversation logic in Swift + C# |
| API credentials | Never leave the server | Must vend to client, even short-lived |
| Latency (GCP → Gemini) | Same-network, ~10-20ms hop | N/A (would be direct) |
| Iterate without client release | Change prompts, models, topics, turn-taking — all backend deploys | Client update required for any conversation logic change |
| Conversation state | Server-side, survives client disconnect/reconnect | Lost if app crashes |
| Usage tracking | Centralized, real-time | Requires client-side reporting |
| Feature permanence | This is not throwaway — proper backend service is the right investment | Client-side hacks accumulate tech debt |

**What the backend orchestrator manages:**
- Opens and maintains the Gemini Live API WebSocket (audio-in/audio-out)
- Injects system prompt with topic context on session start
- Relays audio frames: client → Gemini (therapist speech) and Gemini → client (Pablo response)
- Tracks conversation state (for session resume on disconnect)
- Logs usage per user (rate limiting, analytics)
- Returns session metadata (transcript available after session ends)

**What the client does (minimal):**
- Captures mic audio, sends PCM frames over WebSocket to backend
- Receives audio frames from backend, plays through system audio (AVAudioPlayer)
- AudioCaptureKit records both channels as usual (mic = therapist, system = Pablo)
- UI: topic picker, Pablo Bear image, waveform, session controls

**Fallback path:** If Gemini Live voice quality is insufficient (determined in Phase 1 spike), the backend orchestrator can run the text pipeline instead: receive audio → Whisper STT → Gemini flash-lite text → ElevenLabs TTS → return audio. Same WebSocket API to the client — the client doesn't know or care which mode the backend is using.

**Implementation notes:**
- **WebSocket framework:** FastAPI + `websockets` (already in the Pablo backend stack)
- **Gemini connection:** Backend opens a Gemini Live API WebSocket per active practice session. Since Gemini Live is on Vertex AI in the same GCP project, auth uses the service account directly — no credential vending needed.
- **Audio format:** PCM 16-bit signed little-endian, 16kHz mono (client → backend → Gemini). Gemini returns 24kHz mono — backend can either downsample or let the client handle it.
- **Scaling:** Each active practice session holds two WebSocket connections (client ↔ backend, backend ↔ Gemini). Expected concurrent sessions: low (tens, not thousands) — standard WebSocket scaling is fine.

---

## 6. Conversation Engine Design

### Model: Gemini 2.5 Flash Live API (Primary) / Flash-Lite Text (Fallback)

The backend orchestrator manages the Gemini connection. The client just sends and receives audio — it doesn't know which model or mode the backend is using.

#### Primary: Gemini Live API (`gemini-2.5-flash-live-001`)

Native audio-in → audio-out over a single persistent WebSocket. The backend holds this connection.

```
Client mic → backend WebSocket → Gemini Live → audio response → backend → client speaker
                                 ~200-400ms end-to-end
                                 (backend ↔ Gemini is same GCP region, ~10-20ms hop)
```

**What Gemini Live handles natively (server-side, transparent to client):**
- **Speech recognition** — processes raw audio, no separate STT needed
- **Voice Activity Detection** — built-in turn-taking, detects when therapist stops speaking
- **Response generation** — conversational text generation
- **Voice synthesis** — built-in TTS with configurable voice presets
- **Interruption handling** — therapist can interrupt Pablo mid-response

#### Fallback: Text Pipeline with ElevenLabs

If Gemini's built-in voices aren't warm/expressive enough for Pablo Bear, the backend runs the text pipeline instead — same WebSocket API to the client:

```
Client mic → backend → Whisper STT → Gemini flash-lite (text) → ElevenLabs TTS → backend → client
```

Flash-lite is the same model already deployed for EHR navigation routing (`pablo/backend/app/settings.py:305`), with different config:

| Setting | EHR Navigation | Practice Mode |
|---------|---------------|---------------|
| Temperature | 0.1 (deterministic) | 0.8 (varied, natural) |
| Max output tokens | 2048 | 256 (short conversational turns) |
| Response format | Structured JSON | Free text |

**The client doesn't know or care which mode the backend is using.** Switching between Live API and text pipeline is a backend config change — zero client update.

#### Decision: Prototype Both in Phase 1

The Phase 1 spike compares Gemini Live voice quality vs. ElevenLabs for the Pablo Bear persona. If Live voices are adequate, it wins on latency, cost, and simplicity.

### System Prompt Structure

```
You are Pablo Bear, a warm and friendly bear who is attending therapy.

SCENARIO: {chosen_topic}
PRESENTING ISSUE: {topic_description}

You are in a therapy session with a licensed therapist. Respond as a
realistic therapy client would:
- Share your feelings naturally, don't over-explain
- Sometimes be hesitant or need prompting
- React to the therapist's techniques (reflect, validate, etc.)
- Keep responses conversational (2-4 sentences typical)
- Occasionally ask the therapist questions back
- Show some resistance or ambivalence — don't be a "perfect patient"

IMPORTANT: You are a fictional bear character. Never reference real people,
real patient cases, or real clinical details. Your story is entirely made up.
```

### Topic Catalog (v1)

| Topic | Pablo's Presenting Issue |
|-------|------------------------|
| Generalized Anxiety | Worried about honey supply chain disruptions, can't sleep |
| Work Stress | New job as park ranger, imposter syndrome, demanding boss |
| Grief & Loss | Best friend (a rabbit) moved to another forest |
| Relationship Issues | Partner wants to hibernate longer, communication breakdown |
| Depression | Lost interest in fishing, favorite activity |
| Life Transition | Cubs leaving the den, empty nest feelings |

### Turn-Taking

Turn-taking is managed entirely server-side — the client just streams audio in and plays audio out.

**With Gemini Live API (primary):** Gemini's built-in VAD handles turn detection. The backend relays status signals to the client (speaking/listening/processing) so the UI can update the waveform animation.

**With text pipeline (fallback):** The backend runs its own VAD on the incoming audio stream, then orchestrates Whisper → Gemini → ElevenLabs. Same WebSocket protocol to the client.

### Target Latency Budget

| | Gemini Live (primary) | Text Pipeline (fallback) |
|--|----------------------|--------------------------|
| Client ↔ backend hop | ~10-20ms (same GCP region for Gemini) | ~10-20ms |
| Silence/VAD detection | Built-in (~0s) | Server-side VAD (~1.5s) |
| Speech recognition | Built-in (~0s) | Whisper tiny (~0.5s) |
| LLM response | ~200-400ms to first audio | flash-lite ~0.2s to first token |
| Voice synthesis | Built-in (~0s) | ElevenLabs streaming (~0.3s) |
| **Total turn gap** | **~220-420ms** | **~2.5s** |

---

## 7. HIPAA & Privacy Analysis

### Is Synthetic Conversation PHI?

**No.** HIPAA protects individually identifiable health information about real people. A fictional bear discussing made-up anxiety about honey supply chains is not PHI. However, there are three real risks to address:

### Risk 1: Synthetic Content That "Echoes" a Real Person

**The concern:** What if the AI generates a scenario that closely mirrors a real patient's situation — and someone sees the practice session SOAP note and mistakes it for a real clinical record?

**Mitigations:**
- Pablo Bear is the patient — not a human name, not a human scenario. The SOAP note will say "Patient: Pablo Bear" with bear-specific details (hibernation, den, forest)
- Practice sessions are **permanently tagged** with `source: "practice"` in the backend — cannot be confused with clinical data
- SOAP notes from practice sessions include a banner: "PRACTICE SESSION — Not a clinical record"
- The topic catalog uses intentionally whimsical scenarios (bear-themed) that cannot be confused with real clinical presentations
- Practice session data is **excluded from any analytics, billing, or clinical reporting**

### Risk 2: LLM Leaking Training Data

**The concern:** Could Gemini's responses contain fragments of real patient data from its training set?

**Mitigations:**
- Gemini is not trained on Pablo's patient data (Pablo's data never enters any training pipeline)
- The system prompt explicitly constrains responses to the fictional bear character
- Any resemblance to real situations is coincidental and non-identifiable — the same way a textbook case study isn't PHI
- No real patient names, DOBs, or identifiers are ever in the conversation context

### Risk 3: Storage Hygiene

**The concern:** Practice session recordings and transcripts stored alongside real clinical data could create confusion.

**Mitigations:**
- Practice sessions stored with `source: "practice"` flag — immutable, set at creation
- Backend API will support filtering practice sessions out of clinical views
- Practice recordings are **not encrypted with the clinical encryption key** — they use a separate "practice" key or no encryption (they contain no PHI)
- Data retention: practice sessions auto-delete after 30 days (configurable) vs. clinical records which follow HIPAA retention requirements
- Practice sessions are **never included** in patient record exports or legal holds

### Summary: HIPAA Is Not a Blocker

The combination of (1) obviously fictional patient identity, (2) whimsical non-clinical scenarios, (3) permanent practice tagging, and (4) storage separation means this feature has no HIPAA exposure. A compliance officer should still review the final implementation, but the architecture is clean.

---

## 8. What Already Exists vs. What's New

### Already Built (reuse as-is)

| Component | Status | Notes |
|-----------|--------|-------|
| AudioCaptureKit (dual-stream) | Production | Mic = therapist, system = Pablo |
| `transcribe_session_1on1()` | Production | Labels speakers correctly |
| `render_google_meet()` | Production | Formats transcript for backend |
| `upload_transcript()` | Production | Sends to backend |
| Session lifecycle APIs | Production | Create, start, end, finalize |
| Backend SOAP generation | Production | Generates notes from transcript |
| ElevenLabs TTS integration | Test only | In `e2e_pipeline.rs` — needs extraction |
| Whisper local transcription | Production | Used for real-time STT of therapist |
| Session history UI | Production | Just needs "Practice" badge |

### Needs Building

**Backend (GCP):**

| Component | Effort | Description |
|-----------|--------|-------------|
| Practice session orchestrator | 1 week | WebSocket hub, Gemini Live connection management, session state |
| Practice WebSocket endpoint | 2 days | FastAPI WebSocket route, auth integration |
| Topic catalog + system prompts | 2 days | JSON data files, hot-reloadable |
| Practice session tagging | 1 day | `source: "practice"` on session creation |
| Practice session data policy | 1 day | Auto-delete after 30 days, exclude from reports |

**Client (macOS — first platform):**

| Component | Effort | Description |
|-----------|--------|-------------|
| `PracticeSessionView.swift` | 1 week | SwiftUI view with Pablo image, waveform, controls |
| `PracticeTopicSheet.swift` | 2 days | Topic picker with descriptions |
| `PracticeSessionClient.swift` | 3 days | Thin WebSocket client: send mic PCM, receive + play audio |
| Practice badge in session list | 0.5 day | Visual indicator in `SessionRowView` |

**Estimated Total: ~3.5 weeks** — no client-side VAD, no Whisper integration, no ElevenLabs streaming to build. All conversation intelligence is server-side.

**Additional if falling back to text pipeline (server-side, transparent to client):**

| Component | Effort | Description |
|-----------|--------|-------------|
| Server-side VAD | 2 days | Energy-based silence detection on incoming audio stream |
| Whisper STT integration | 1 day | Already available in the backend |
| ElevenLabs TTS streaming | 2 days | Backend calls ElevenLabs, returns audio chunks to client |

The biggest unknowns are (1) audio routing verification (AVAudioPlayer output captured by AudioCaptureKit), (2) Gemini Live voice quality for the Pablo Bear persona, and (3) WebSocket reliability over long sessions.

---

## 9. Technical Risks & Open Questions

### Risk: Audio Routing

**Question:** Does AudioCaptureKit capture `AVAudioPlayer` output as system audio?

**Likely yes** — AudioCaptureKit captures all system audio via the screen recording permission (similar to how it captures Zoom audio from the remote participant). But this needs verification on the first spike.

**Fallback:** If system audio capture doesn't pick up local playback, we can write Pablo's TTS audio directly to a file and merge it with the mic recording post-session (like the e2e test does). Less elegant but functional.

### Risk: Turn-Taking Latency

With Gemini Live API (Option A), the ~200-400ms turn gap is already natural — this risk is largely eliminated. With the text pipeline (Option B), 2.5 seconds is the target but could feel slow. Mitigations for Option B:
- Start Gemini API call while therapist is still finishing (speculative)
- Pre-generate opening lines for common therapeutic techniques
- Use ElevenLabs streaming (chunks play while still generating)
- Upgrade from flash-lite to flash if quality insufficient (backend config change, no client update)

### Risk: Conversation Quality

The AI needs to be a believable-enough therapy client to make the practice useful. Too robotic = useless training. Too "perfect" = unrealistic.

**Mitigation:** Invest in prompt engineering. Test with actual therapists. Iterate on the system prompt and topic descriptions. The automated test mode (section 11) enables rapid iteration without manual speaking.

### Risk: WebSocket Disconnection

Client loses WebSocket connection to backend mid-session (network blip, laptop sleep).

**Mitigation:** Backend retains session state (conversation history, topic, turn count) keyed by session ID. Client reconnects with session ID and resumes. Gemini Live connection may need to be re-established server-side, but the conversation context is replayed from the backend's state.

### Open Questions

1. **Should practice sessions count toward any usage limits or billing?** (Probably not for v1)
2. **Should we support couples practice?** (Two AI characters — defer to v2)
3. **Can therapists create custom topics?** (Free-text scenario — nice to have, not v1)
4. **Should there be a "difficulty" setting?** (Resistant client vs. cooperative — v2)

---

## 10. Phased Delivery

### Phase 1: Audio Routing + Voice Quality Spike (1 week)

Two things to validate before building anything else:

1. **Audio routing:** Verify that `AVAudioPlayer` → system audio → AudioCaptureKit works. Play a WAV file, capture with RecordingService, confirm it shows up in the system audio channel.
2. **Gemini Live voice quality:** Stand up a minimal Gemini Live API WebSocket on GCP, give it the Pablo Bear system prompt, and evaluate whether the built-in voices are warm/expressive enough. Compare side-by-side with ElevenLabs on the same script.

**Phase 1 output:** Go/no-go decision on Gemini Live vs. text pipeline with ElevenLabs. (Either way, the backend orchestrator architecture is the same — only the backend's internal implementation changes.)

### Phase 2: Backend Orchestrator + Client MVP (2 weeks)

- Practice session orchestrator on GCP (FastAPI WebSocket)
- Gemini Live API connection management (or text pipeline fallback)
- Thin WebSocket client on macOS — send mic PCM, receive + play audio
- Audio routing: received audio → AVAudioPlayer → system audio → captured by AudioCaptureKit
- One hardcoded topic (Generalized Anxiety)

### Phase 3: Practice Session UI (1 week)

- `PracticeSessionView` with Pablo Bear image and controls
- Topic picker
- Integration with existing `RecordingService` and session lifecycle
- Practice session tagging (`source: "practice"`)

### Phase 4: Pipeline Integration & Polish (1 week)

- End session → transcribe → upload → SOAP note (using existing pipeline)
- Practice badge in session history
- Data retention policy (auto-delete after 30 days)
- Latency tuning on turn-taking

### Phase 5: Automated Test Mode (3 days)

- `AudioSourceProtocol` abstraction (mic vs. injected buffer)
- AI therapist persona (second Gemini call with therapist system prompt)
- `AutomatedPracticeSession` orchestrator — runs full loop with no human
- BlackHole integration guide for quick manual testing

---

## 11. Automated Test Mode

For end-to-end pipeline testing without a human therapist, practice mode supports a fully automated loop where an AI plays both sides of the conversation.

### Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  Automated Practice Session                                      │
│                                                                  │
│  ┌─────────────────────┐          ┌─────────────────────┐       │
│  │  AI Therapist        │          │  AI Patient          │       │
│  │  (Gemini flash-lite) │          │  (Gemini flash-lite) │       │
│  │                      │          │  (Pablo Bear)        │       │
│  │  System prompt:      │          │  System prompt:      │       │
│  │  "Licensed therapist │          │  "Pablo Bear in      │       │
│  │   conducting session" │          │   therapy session"   │       │
│  └──────────┬───────────┘          └──────────┬───────────┘       │
│             │                                 │                   │
│             ▼                                 ▼                   │
│  ┌─────────────────────┐          ┌─────────────────────┐       │
│  │  ElevenLabs TTS      │          │  ElevenLabs TTS      │       │
│  │  (therapist voice)   │          │  (Pablo voice)       │       │
│  └──────────┬───────────┘          └──────────┬───────────┘       │
│             │                                 │                   │
│             ▼                                 ▼                   │
│  ┌─────────────────┐              ┌─────────────────┐            │
│  │  Mic channel     │              │  System audio    │            │
│  │  (injected or    │              │  (AVAudioPlayer) │            │
│  │   BlackHole)     │              │                  │            │
│  └────────┬─────────┘              └────────┬─────────┘            │
│           │                                 │                     │
│           └────────────┬────────────────────┘                     │
│                        ▼                                          │
│           ┌─────────────────────┐                                 │
│           │  AudioCaptureKit     │                                 │
│           │  (dual-stream)       │                                 │
│           └────────────┬─────────┘                                 │
│                        ▼                                          │
│           ┌─────────────────────┐                                 │
│           │  Existing pipeline   │                                 │
│           │  transcribe → SOAP   │                                 │
│           └──────────────────────┘                                 │
└──────────────────────────────────────────────────────────────────┘
```

### Two Approaches (both supported)

#### Approach 1: BlackHole Virtual Audio (quick manual testing)

No code changes required. Install BlackHole, point system mic input to it, and run a script that plays therapist TTS audio to BlackHole's output. AudioCaptureKit captures it as the "therapist" mic channel.

```bash
brew install blackhole-2ch
# Set System Settings → Sound → Input to "BlackHole 2ch"
# Run test script that plays therapist TTS to BlackHole
```

**Best for:** Quick manual testing, ad-hoc demos, debugging audio routing.

#### Approach 2: Audio Injection via Protocol (programmatic, CI-friendly)

An `AudioSourceProtocol` abstraction lets `RecordingService` accept audio buffers instead of reading from the physical mic:

```swift
protocol AudioSourceProtocol {
    /// Start delivering audio buffers to the handler
    func startCapture(handler: @escaping (AVAudioPCMBuffer) -> Void) async throws
    func stopCapture() async
}

/// Production: wraps the real microphone
struct MicrophoneAudioSource: AudioSourceProtocol { ... }

/// Testing: accepts injected audio buffers
struct InjectedAudioSource: AudioSourceProtocol {
    func inject(_ buffer: AVAudioPCMBuffer) { ... }
}
```

The `AutomatedPracticeSession` orchestrator runs the full loop:

```swift
final class AutomatedPracticeSession {
    let topic: PracticeTopic
    let maxTurns: Int  // e.g., 10 turns = ~5 min session
    
    func run() async throws -> Session {
        // 1. Start recording with InjectedAudioSource
        // 2. Loop:
        //    a. AI therapist generates text (Gemini, therapist persona)
        //    b. ElevenLabs TTS → audio buffer
        //    c. Inject buffer into mic channel via InjectedAudioSource
        //    d. AI patient (Pablo) responds via ConversationEngine
        //    e. Pablo's TTS plays through system audio (captured automatically)
        // 3. End session → standard pipeline → SOAP note
        // 4. Return completed session with SOAP note
    }
}
```

**Best for:** CI regression tests, automated SOAP note quality checks, rapid prompt iteration.

### Therapist Persona Prompt

```
You are a licensed therapist conducting a session with a client
named Pablo Bear. Use standard therapeutic techniques:
- Reflective listening and paraphrasing
- Open-ended questions
- Validation and normalization
- Gentle probing when the client is avoidant

Keep responses to 2-3 sentences. Be warm but professional.
Topic: {topic}
```

---

## 12. Decision Log

| Decision | Choice | Rationale |
|----------|--------|-----------|
| No Zoom/Recall.ai | Native window | We already capture mic + system audio; adding Zoom is complexity for zero benefit |
| Same backend for sessions/SOAP | Yes | The whole point is exercising the real pipeline |
| Backend WebSocket orchestrator (GCP) | Yes | One implementation for both platforms; no API keys on client; iterate prompts/models without client release; same GCP region as Gemini = ~10-20ms hop |
| Gemini 2.5 Flash for conversation | Live API preferred, flash-lite text as fallback | Live API gives ~200-400ms turns, built-in VAD, single connection. Backend switches modes transparently — client is just an audio pipe |
| Not patenting | Correct | Moat is execution speed + brand, not IP. Patent would cost $15-30K, take 3-5 years, produce narrow claims. Spend the money on shipping faster. |
| Pablo Bear as patient (not human) | Yes | Eliminates HIPAA concerns, reinforces brand, prevents "echoing" real people |
| Whimsical topics (bear-themed) | Yes | Fun, on-brand, and impossible to confuse with real clinical data |
| Phase 1 = audio routing + voice quality spike | Yes | Highest-risk questions: does AudioCaptureKit capture local playback? Are Gemini Live voices good enough? |
| Dual test approach (BlackHole + injection) | Yes | BlackHole for quick manual testing; audio injection protocol for CI and automated iteration |
