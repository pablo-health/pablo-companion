# Lightweight Model Research: Agentic SOAP Note Entry

## Problem Statement

After Pablo generates SOAP notes, therapists must manually enter them into their EHR system (e.g., SimplePractice, TherapyNotes, Jane App). We want to automate this using Playwright browser automation with an LLM handling the dynamic navigation intelligence.

**Key constraints:**
- Must navigate to correct patient, verify name + appointment time match
- Must handle EHR UI changes gracefully (vendor may change their frontend)
- Must handle dynamic data (patient lists, appointment times)
- HIPAA: patient names + SOAP notes are PHI
- Cost-sensitive: therapists are small businesses

---

## Architecture: Cached Routes + LLM Fallback

The critical insight is that **95%+ of EHR navigation is deterministic**. The DOM structure of a given EHR doesn't change between sessions. We should:

1. **Learn once** — Agent navigates the EHR, we record the accessibility tree path as a "route"
2. **Cache the route** — Store the sequence of selectors/actions server-side per EHR system
3. **Deterministic replay** — If accessibility indicators are an exact match, replay without LLM
4. **LLM fallback** — Only invoke the model when the DOM doesn't match the cached route

This means the LLM handles two distinct tasks:
- **Dynamic data matching** (always needed): Find patient "Jane Smith" in a list, verify "2:00 PM" appointment
- **Route recovery** (rare): When EHR vendor changes their UI, re-learn the navigation path

### Where Dynamic Data Needs Intelligence

Even with cached routes, you need to handle:
- **Patient search/selection**: Finding the right patient in a list (text matching in DOM)
- **Appointment verification**: Confirming date/time match
- **Form field mapping**: Knowing which field is Subjective vs Objective vs Assessment vs Plan

**However**, much of this can be done with structured DOM search (no LLM needed):
```python
# Deterministic: find patient by text match in accessibility tree
patient_element = find_element_by_text(accessibility_tree, patient_name)

# Deterministic: verify appointment time
time_element = find_element_by_text(accessibility_tree, appointment_time)

# LLM only needed when: element not found, ambiguous matches, UI changed
```

The LLM is the **fallback brain**, not the primary navigator.

---

## Orchestration: deepagents + Playwright MCP

[langchain-ai/deepagents](https://github.com/langchain-ai/deepagents) is a good fit as the **orchestration layer**:
- Built on LangGraph, supports sub-agent delegation
- MCP (Model Context Protocol) support via `langchain-mcp-adapters`
- Planning/todo system for multi-step task tracking
- Provider-agnostic — works with any model via `init_chat_model`

**deepagents does NOT have built-in browser automation.** It would be integrated with:
- Playwright MCP server for browser actions (navigate, click, fill, extract)
- Our cached route system for deterministic replay
- Small model inference for fallback/recovery

### Proposed Stack

```
┌─────────────────────────────────────┐
│  Pablo Backend (FastAPI/Flask)       │
│  ┌───────────────────────────────┐  │
│  │  deepagents orchestrator      │  │
│  │  ├── Route Cache (per EHR)    │  │
│  │  ├── Playwright MCP tools     │  │
│  │  └── LLM fallback (Vertex AI) │  │
│  └───────────────────────────────┘  │
│  ┌───────────────────────────────┐  │
│  │  Cached Route Engine          │  │
│  │  - Accessibility tree matcher │  │
│  │  - Deterministic text search  │  │
│  │  - DOM diff detector          │  │
│  └───────────────────────────────┘  │
└─────────────────────────────────────┘
         │
         ▼ (headless browser)
┌─────────────────────────────────────┐
│  EHR System (SimplePractice, etc.)  │
└─────────────────────────────────────┘
```

---

## Model Research: What's the Lightest Weight?

### Tier 1: Purpose-Built Browser Agent Models

| Model | Total Params | Active Params | Browser Task? | Notes |
|-------|-------------|---------------|---------------|-------|
| **BU-30B-A3B** | 30B | **3B** (MoE) | **Yes — built for this** | Browser Use's own model. Fine-tuned on Qwen3-VL-30B-A3B for browser automation. ~$0.005/task (200 tasks/$1). 1.2s/step. Open source on HuggingFace. |
| **BU 2.0** | — | — | Yes | 83.3% accuracy on Browser Use benchmark. Matches Claude Opus 4.5 accuracy, 40% faster. Commercial. |

**BU-30B-A3B is the standout answer.** It's a MoE model — 30B total but only 3B parameters activate per inference. Purpose-built for browser automation with DOM understanding and visual reasoning. Runs on a single GPU. Released Dec 2025, open source.

### Tier 2: Small General Models with Tool-Calling

| Model | Params | Tool Calling | Browser Nav Viable? | Notes |
|-------|--------|-------------|---------------------|-------|
| **Qwen2.5-3B** | 3B | Yes (native) | Possible with fine-tuning | Best small model for structured output/tool use |
| **Qwen2.5-1.5B** | 1.5B | Yes (native) | Marginal | Can do simple tool calls but struggles with complex multi-step |
| **Phi-3.5-mini** | 3.8B | Via prompting | Possible | Strong reasoning for size, but not tuned for browser tasks |
| **Gemma 2 2B** | 2B | Via prompting | Unlikely standalone | No native tool calling; community fine-tunes exist |
| **FunctionGemma** | 270M | Yes (native) | No — too simple | 85% accuracy on single function calls after fine-tuning, but can't handle multi-step navigation |
| **xLAM-1B** | 1B | Yes (native) | Marginal | Salesforce's tool-calling model, strong on BFCL benchmark for size |
| **SmolLM2-1.7B** | 1.7B | Via prompting | No | General purpose, not suited for agentic tasks |

### Tier 3: API Models (for comparison)

| Model | Cost | Browser Nav? | Notes |
|-------|------|-------------|-------|
| **Gemini 2.0 Flash** | ~$0.10/1M tokens | Yes | Available on Vertex AI, good tool use |
| **Claude Haiku 4.5** | $0.25/$1.25 per 1M tokens | Yes | Excellent tool use, fast |
| **GPT-4o-mini** | $0.15/$0.60 per 1M tokens | Yes | Good tool use |

---

## Can a 1B Model Do the Full Navigation?

### Short answer: **No, not reliably for general navigation. But it doesn't need to.**

### Detailed analysis:

**What a 1B model CAN do:**
- Single function/tool calls with clear schemas
- Simple text matching ("find element containing 'Jane Smith'")
- Structured JSON output generation
- Following a pre-defined script with branching

**What a 1B model CANNOT reliably do:**
- Multi-step reasoning about unfamiliar DOM structures
- Recovery from unexpected UI states
- Understanding complex accessibility trees
- Planning a navigation path from scratch

**What a 3B model (specifically BU-30B-A3B with 3B active) CAN do:**
- Full browser navigation with DOM understanding
- Visual reasoning about page layout
- Multi-step task completion
- Recovery when pages don't look as expected

### The Hybrid Architecture Changes the Question

With cached routes + deterministic text matching, the LLM's job shrinks to:

| Task | Frequency | Model Needed |
|------|-----------|-------------|
| Replay cached route | 90% of actions | **None** (deterministic) |
| Find patient by name in DOM | Every session | **None** (text search) |
| Verify appointment time | Every session | **None** (text match) |
| Fill SOAP note fields | Every session | **None** (cached field selectors) |
| Handle unexpected DOM change | ~5% of sessions | **3B+ model** |
| Re-learn navigation route | Rare (EHR update) | **3B+ model** |

**Bottom line: A 1B model is too small for the recovery/re-learning task. But with the hybrid architecture, you only need a 3B model for ~5% of interactions.**

---

## Recommendation: Backend-Hosted on GCP (Vertex AI)

### Why Backend, Not Local

| Factor | Backend | Local |
|--------|---------|-------|
| **HIPAA** | Already covered by BAA with GCP | Would need to secure every client machine |
| **Route caching** | Centralized — one learned route benefits all therapists on same EHR | Each machine learns independently |
| **Model updates** | Deploy once, all clients benefit | Push updates to every machine |
| **Hardware requirements** | None on client | Need GPU or fast CPU |
| **Latency** | Network round-trip (~100-200ms) | Faster for inference, but browser is remote anyway |
| **Cost control** | Predictable, can batch | Variable per machine |

### Recommended GCP Setup

**Primary path (95% of sessions): No model inference needed**
- Cached routes + deterministic DOM matching
- Cost: ~$0/session

**Fallback path (5% of sessions): BU-30B-A3B or Gemini Flash**

Option A: **Self-hosted BU-30B-A3B on Vertex AI / GKE**
- Single L4 GPU ($0.70/hr on GKE) or T4 ($0.35/hr)
- 3B active params → fast inference
- ~$0.005/task, ~200 tasks per dollar
- Could serve many therapists from one GPU
- Open source, no per-token API costs

Option B: **Gemini 2.0 Flash via Vertex AI API**
- No infrastructure to manage
- ~$0.10/1M input tokens, $0.40/1M output tokens
- Per-session cost estimate (when LLM needed):
  - ~5-10 navigation actions × ~500 tokens each = ~5K tokens
  - Cost: ~$0.003/session
- Available immediately, no model hosting

### Cost Estimate (8 sessions/day, 22 days/month)

| Scenario | Monthly Cost |
|----------|-------------|
| 100% cached (no LLM) | $0 |
| 5% fallback with Gemini Flash | ~$0.05/therapist/month |
| 20% fallback with Gemini Flash | ~$0.20/therapist/month |
| 100% LLM (no caching) | ~$1.00/therapist/month |
| Self-hosted BU-30B-A3B (shared GPU) | ~$250/month fixed, unlimited therapists |

**The costs are negligible.** Even without caching, using Gemini Flash for every session costs ~$1/month per therapist.

---

## Navigation Caching Design

### How Route Caching Works

```python
# Route = ordered list of cached steps
@dataclass
class CachedStep:
    action: str  # "click", "fill", "navigate"
    selector: str  # CSS/accessibility selector
    accessibility_fingerprint: dict  # snapshot of nearby a11y tree
    expected_result: str  # what the page should look like after
    dynamic_data_key: str | None  # "patient_name", "appointment_time", etc.

@dataclass
class CachedRoute:
    ehr_system: str  # "simplepractice", "therapynotes"
    route_name: str  # "navigate_to_soap_note"
    steps: list[CachedStep]
    learned_at: datetime
    success_count: int  # how many times this route worked
    last_success: datetime
```

### Route Execution Flow

```
1. Load cached route for this EHR system
2. For each step:
   a. Get current accessibility tree
   b. Compare fingerprint → exact match?
      YES → Execute action deterministically
            If dynamic_data_key, do text search for the value
      NO  → Call LLM with:
            - Current accessibility tree
            - What we're trying to do
            - What we expected to see
            → LLM figures out the new path
            → Update cached route with new step
3. On success: increment success_count
4. On failure: flag for human review
```

### Navigation Can Be Cached Similarly

Yes — the full navigation path ("login → dashboard → patient list → search → select patient → notes tab → new SOAP note") can be cached as a route. Each EHR only needs to be learned once, then all therapists on that EHR benefit.

**Cache invalidation**: When a cached route fails 3+ times in a row, trigger a full re-learning session with the larger model.

---

## HIPAA Considerations

| Concern | Mitigation |
|---------|-----------|
| Patient names sent to LLM | GCP Vertex AI supports BAA; data stays in your GCP project |
| SOAP note content in prompts | Same — Vertex AI with BAA covers this |
| Browser session contains PHI | Run Playwright headless on backend, not client |
| Route cache contains PHI? | No — routes store selectors and structure, not patient data |
| Audit trail | Log all LLM-assisted navigation actions |

Running the browser on the backend also solves the "therapist's computer" problem entirely — Playwright runs headless in your GCP environment, not on their machine.

---

## Key Risks

1. **EHR Terms of Service**: Some EHRs may prohibit automated access. Need legal review per EHR vendor.
2. **Authentication**: Need therapist's EHR credentials stored securely. Session/cookie management for Playwright.
3. **EHR rate limiting**: Automated navigation might trigger abuse detection.
4. **Liability**: If the agent enters notes in the wrong patient's chart, that's a serious issue. Need verification step.
5. **Vendor pushback**: "the agent kicking in if the other integration is trying to play whack a mole" — if an EHR actively fights automation, this becomes an arms race.

### Mitigation: Verification Gate

Before committing any SOAP note entry, show the therapist a confirmation:
```
Pablo found: Jane Smith, 2:00 PM on March 23
SOAP note will be entered in [EHR System] → Patient Notes → Today's Session
[Confirm] [Cancel]
```

This keeps the human in the loop for the most critical step.

---

## Summary & Recommendation

| Decision | Recommendation |
|----------|---------------|
| **Architecture** | Cached routes + LLM fallback (hybrid) |
| **Orchestration** | deepagents + Playwright MCP |
| **Model for fallback** | **Gemini 2.0 Flash on Vertex AI** (simplest) or **BU-30B-A3B self-hosted** (cheapest at scale) |
| **Can 1B do it?** | No for general navigation. With caching, you rarely need a model at all, and when you do, 3B active params (BU-30B-A3B) is the floor. |
| **Hosting** | Backend (GCP) — centralizes routes, simplifies HIPAA, removes client hardware dependency |
| **Cost** | Negligible: $0.05-$1/therapist/month with Gemini Flash |
| **Biggest risk** | EHR vendor ToS and pushback, not model capability or cost |
