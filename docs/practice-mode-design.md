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

## 2. User Experience

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

## 3. Architecture

### High-Level Flow

```
┌─────────────────────────────────────────────────────────────────┐
│  Pablo Companion (macOS)                                        │
│                                                                 │
│  ┌──────────────────┐    ┌─────────────────────────────────┐    │
│  │ Practice Session  │    │ Audio Capture (existing)        │    │
│  │ Window (SwiftUI)  │    │                                 │    │
│  │                   │    │  Mic ──→ therapist channel      │    │
│  │  Pablo Bear image │    │  System audio ──→ client channel│    │
│  │  + waveform       │    │                                 │    │
│  └────────┬──────────┘    └──────────┬──────────────────────┘    │
│           │                          │                           │
│           ▼                          │                           │
│  ┌────────────────────┐              │                           │
│  │ Conversation Engine │             │                           │
│  │ (turn management)   │             │                           │
│  │                     │             │                           │
│  │  1. Detect silence  │             │                           │
│  │     (therapist done)│             │                           │
│  │  2. STT on therapist│             │                           │
│  │     utterance       │             │                           │
│  │  3. LLM response    │─────────────┼──── API calls ──────────────▶
│  │  4. ElevenLabs TTS  │             │                           │
│  │  5. Play audio      │─── system ──┘  (captured as "client")  │
│  │     (AVAudioPlayer) │                                         │
│  └────────────────────┘                                          │
│           │                                                      │
│           ▼  (on "End Session")                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ Existing Pipeline (unchanged)                              │  │
│  │  transcribe_session_1on1() → render_google_meet()          │  │
│  │  → upload_transcript() → finalize_session()                │  │
│  │  → backend generates SOAP note                             │  │
│  └────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### The Key Trick: Audio Routing

The existing AudioCaptureKit setup captures **mic audio** (therapist) and **system audio** (everything else) as separate streams. If Pablo's TTS response plays through the system audio path (via `AVAudioPlayer` or `NSSound`), it gets captured automatically as the "client" channel.

**This means zero changes to the transcription pipeline.** The existing `transcribe_session_1on1()` labels mic as THERAPIST and system as CLIENT — which is exactly correct for practice mode.

### Components

| Component | Location | New vs. Existing |
|-----------|----------|-----------------|
| Practice Session window | `mac/Views/PracticeSessionView.swift` | **New** |
| Topic picker sheet | `mac/Views/PracticeTopicSheet.swift` | **New** |
| Conversation engine | `mac/Services/ConversationEngine.swift` | **New** |
| Turn detector (VAD) | `mac/Services/TurnDetector.swift` | **New** |
| Audio capture | `mac/Services/RecordingService.swift` | Existing, unchanged |
| Transcription pipeline | `core/src/session_pipeline.rs` | Existing, unchanged |
| Session lifecycle API | `core/src/api_client.rs` | Existing, unchanged |
| SOAP note generation | Pablo backend | Existing, unchanged |

---

## 4. The Backend Question

**Recommendation: Use the same Pablo backend for session lifecycle and SOAP notes. Use a separate lightweight service (or client-side calls) for the AI conversation engine.**

### Why Same Backend for Sessions/SOAP

The whole point is to exercise the real pipeline. Practice sessions should:
- Create a real `Session` object via `POST /api/sessions`
- Upload a real transcript via `POST /api/sessions/{id}/transcripts`
- Generate a real SOAP note through the existing backend pipeline
- Appear in session history (tagged as practice)

Building a separate backend for this would mean duplicating the entire session/SOAP pipeline — defeating the purpose.

### Why Separate Service for the Conversation Engine

The AI conversation loop (LLM chat + ElevenLabs TTS) is a fundamentally different workload:

| Concern | Pablo Backend | Conversation Engine |
|---------|--------------|-------------------|
| Latency requirement | Seconds OK | Sub-second (conversational feel) |
| State model | Stateless REST | Stateful (chat history per session) |
| External dependencies | PostgreSQL, S3, Whisper | Claude/GPT API, ElevenLabs API |
| Scaling pattern | Many users, async jobs | One active session per user, real-time |
| PHI exposure | High (real patient data) | **Zero** (synthetic only) |

**Three options, in order of preference:**

#### Option A: Client-Side Only (Recommended for v1)

The companion app calls Claude API and ElevenLabs directly. No backend needed for the conversation.

```
Companion ──→ Claude API (chat completion)
Companion ──→ ElevenLabs API (TTS)
```

**Pros:** Simplest. Lowest latency. No new infrastructure. API keys stored in Keychain.
**Cons:** API keys on client. Rate limits per-client.

#### Option B: Thin Proxy on Pablo Backend

Add two proxy endpoints to the existing backend that forward to Claude/ElevenLabs with the backend's API keys.

```
Companion ──→ POST /api/practice/chat ──→ Claude API
Companion ──→ POST /api/practice/tts  ──→ ElevenLabs API
```

**Pros:** API keys stay server-side. Can add usage tracking/limits.
**Cons:** Adds latency (extra hop). Backend team needs to build/maintain.

#### Option C: Dedicated Microservice

A standalone service (Python FastAPI or Rust) that handles the full conversation loop including streaming.

**Pros:** Clean separation. Can optimize independently.
**Cons:** Overkill for v1. Another thing to deploy and monitor.

**Verdict: Start with Option A (client-side). Migrate to Option B if API key management becomes a concern.**

---

## 5. Conversation Engine Design

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

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  Therapist   │     │   Silence    │     │    Pablo     │
│  speaking    │────▶│  detected    │────▶│  responding  │
│              │     │  (VAD, ~1.5s)│     │              │
└──────────────┘     └──────────────┘     └──────┬───────┘
       ▲                                         │
       │              ┌──────────────┐           │
       └──────────────│  Pablo done  │◀──────────┘
                      │  (TTS ended) │
                      └──────────────┘
```

**Voice Activity Detection (VAD):** Use a simple energy-based detector on the mic stream. When audio energy drops below threshold for ~1.5 seconds, consider the therapist's turn complete.

**Streaming approach:**
1. While therapist speaks, buffer mic audio
2. On silence detection, send buffered audio to Whisper (local, fast — tiny model is fine for clear mic input)
3. Send transcribed text to Claude API (streaming response)
4. Stream Claude's response text to ElevenLabs TTS (streaming audio)
5. Play TTS audio through system audio path as chunks arrive
6. When TTS playback finishes, listen for therapist again

**Target latency budget:**

| Step | Target | Notes |
|------|--------|-------|
| Silence detection | ~1.5s | Configurable threshold |
| Local Whisper (tiny) | ~0.5s | Short utterances, fast model |
| Claude API (streaming) | ~0.3s to first token | Streaming means we start TTS early |
| ElevenLabs TTS (streaming) | ~0.3s to first audio | Use streaming endpoint |
| **Total turn gap** | **~2.5s** | Feels natural for a "thoughtful" client |

---

## 6. HIPAA & Privacy Analysis

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

**The concern:** Could Claude's responses contain fragments of real patient data from its training set?

**Mitigations:**
- Claude is not trained on Pablo's patient data (Pablo's data never enters any training pipeline)
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

## 7. What Already Exists vs. What's New

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

| Component | Effort | Description |
|-----------|--------|-------------|
| `PracticeSessionView.swift` | 1 week | SwiftUI view with Pablo image, waveform, controls |
| `PracticeTopicSheet.swift` | 2 days | Topic picker with descriptions |
| `ConversationEngine.swift` | 1.5 weeks | Orchestrates the turn-taking loop |
| `TurnDetector.swift` | 3 days | VAD on mic stream for silence detection |
| Claude API client (in core/) | 3 days | Simple chat completion, could go in Rust or stay Swift |
| ElevenLabs streaming TTS | 3 days | Extract from e2e test, add streaming playback |
| Topic catalog + system prompts | 2 days | JSON/plist with topics and prompt templates |
| Practice session tagging | 1 day | `source: "practice"` on session creation |
| Practice badge in session list | 0.5 day | Visual indicator in `SessionRowView` |
| Practice session data policy | 1 day | Auto-delete, exclude from reports |

### Estimated Total: ~4-5 weeks

The biggest unknowns are turn-taking latency tuning and audio routing verification (confirming AVAudioPlayer output is captured by AudioCaptureKit as system audio).

---

## 8. Technical Risks & Open Questions

### Risk: Audio Routing

**Question:** Does AudioCaptureKit capture `AVAudioPlayer` output as system audio?

**Likely yes** — AudioCaptureKit captures all system audio via the screen recording permission (similar to how it captures Zoom audio from the remote participant). But this needs verification on the first spike.

**Fallback:** If system audio capture doesn't pick up local playback, we can write Pablo's TTS audio directly to a file and merge it with the mic recording post-session (like the e2e test does). Less elegant but functional.

### Risk: Turn-Taking Latency

2.5 seconds is the target but could feel slow. Options to improve:
- Start Claude API call while therapist is still finishing (speculative)
- Use a faster/smaller LLM for initial response, Claude for quality
- Pre-generate opening lines for common therapeutic techniques
- Use ElevenLabs streaming (chunks play while still generating)

### Risk: Conversation Quality

The AI needs to be a believable-enough therapy client to make the practice useful. Too robotic = useless training. Too "perfect" = unrealistic.

**Mitigation:** Invest in prompt engineering. Test with actual therapists. Iterate on the system prompt and topic descriptions.

### Open Questions

1. **Should practice sessions count toward any usage limits or billing?** (Probably not for v1)
2. **Should we support couples practice?** (Two AI characters — defer to v2)
3. **Can therapists create custom topics?** (Free-text scenario — nice to have, not v1)
4. **Should there be a "difficulty" setting?** (Resistant client vs. cooperative — v2)
5. **Where do Claude API keys come from?** Client-side = user provides key? Or Pablo provides as part of subscription?

---

## 9. Phased Delivery

### Phase 1: Audio Routing Spike (1 week)

Verify that `AVAudioPlayer` → system audio → AudioCaptureKit works. Build a minimal test: play a WAV file, capture with RecordingService, confirm it shows up in the system audio channel. This is the single biggest technical risk — validate it first.

### Phase 2: Conversation Engine MVP (2 weeks)

- Turn detector (VAD)
- Claude API integration (non-streaming first)
- ElevenLabs TTS playback
- Basic turn loop: listen → transcribe → respond → speak → listen
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

---

## 10. Decision Log

| Decision | Choice | Rationale |
|----------|--------|-----------|
| No Zoom/Recall.ai | Native window | We already capture mic + system audio; adding Zoom is complexity for zero benefit |
| Same backend for sessions/SOAP | Yes | The whole point is exercising the real pipeline |
| Separate service for AI conversation | Client-side (v1) | Lowest latency, simplest, no PHI in conversation |
| Pablo Bear as patient (not human) | Yes | Eliminates HIPAA concerns, reinforces brand, prevents "echoing" real people |
| Whimsical topics (bear-themed) | Yes | Fun, on-brand, and impossible to confuse with real clinical data |
| Phase 1 = audio routing spike | Yes | Highest-risk technical question; validate before building everything else |
