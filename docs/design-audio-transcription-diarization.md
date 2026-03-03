# Design Doc: Audio Transcription with Speaker Diarization

**Status:** Draft — awaiting review
**Author:** Kurt Niemi
**Date:** 2026-03-03
**Repos affected:** `pablo-companion`, `AudioCaptureKit`, `pablo` (backend)

---

## 1. Problem

Therapists record sessions via Pablo Companion. Today the app captures audio and uploads the WAV file, but there is no transcription or speaker labeling. The downstream session workflow (SOAP note generation) expects a **Google Meet-style transcript** — timestamped, speaker-labeled text — and currently has no way to get one from Pablo-recorded audio.

We need to turn a raw audio recording into a structured transcript with speaker diarization, where each utterance is attributed to a named participant (Therapist, Patient, Client A, Client B).

### Requirements

| Requirement | Detail |
|-------------|--------|
| HIPAA compliance | Non-negotiable. PHI must be encrypted at rest and in transit. Minimize data exposure. |
| Speaker diarization | Attribute each utterance to a speaker. Support 2 speakers (1:1 therapy) and 3 speakers (couples counseling). |
| Speaker labeling | Map generic "Speaker 0/1/2" clusters to named roles (Therapist, Patient, Client A, Client B). |
| Therapist enrollment | Record a voice sample once during onboarding to auto-identify the therapist in all future sessions. |
| Couples support | For 3-speaker sessions, identify therapist via enrollment; label remaining speakers as Client A / Client B (either via enrollment or one-time manual mapping). |
| Output format | Google Meet transcript format (timestamp + speaker name + text, grouped by turns) — this is what the downstream session/SOAP note pipeline consumes. |
| Processing mode | Batch (after session ends). Real-time is not required. |
| Dual compute modes | Local on-device processing (default) OR upload to Pablo cloud backend. User/org can choose. |
| Backend storage | Transcripts are stored in the Pablo backend as PHI. Audio is optionally stored with configurable TTL. |

---

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Pablo Companion (macOS / Windows)         │
│                                                             │
│  ┌──────────────┐    ┌──────────────────────────────────┐   │
│  │ AudioCapture  │    │     TranscriptionService         │   │
│  │ Kit (record)  │───▶│                                  │   │
│  │               │    │  ┌────────────┐ ┌─────────────┐  │   │
│  │ Ch1: Mic      │    │  │  Local     │ │  Cloud      │  │   │
│  │ Ch2: System   │    │  │  Backend   │ │  Backend    │  │   │
│  └──────────────┘    │  │ (whisper   │ │ (upload to  │  │   │
│                       │  │  + diariz) │ │  Pablo API) │  │   │
│                       │  └─────┬──────┘ └──────┬──────┘  │   │
│                       │        │               │         │   │
│                       │        ▼               ▼         │   │
│                       │   ┌─────────────────────────┐    │   │
│                       │   │ Canonical Transcript     │    │   │
│                       │   │ Schema (JSON)            │    │   │
│                       │   └────────────┬────────────┘    │   │
│                       └────────────────┼────────────────┘   │
│                                        │                     │
│                    ┌───────────────────┼──────────────┐      │
│                    │  Speaker Labeling │              │      │
│                    │  (enrollment      │              │      │
│                    │   matching)       │              │      │
│                    └───────────────────┼──────────────┘      │
│                                        │                     │
│                    ┌───────────────────▼──────────────┐      │
│                    │  Meet-Style Formatter            │      │
│                    │  (renders for downstream)        │      │
│                    └───────────────────┬──────────────┘      │
└────────────────────────────────────────┼─────────────────────┘
                                         │
                              POST /api/sessions/{id}/transcript
                                         │
                                         ▼
                            ┌─────────────────────────┐
                            │   Pablo Backend          │
                            │   (FastAPI)              │
                            │                          │
                            │   Stores transcript      │
                            │   as PHI                 │
                            └─────────────────────────┘
```

### Key Design Decisions

1. **One pipeline, two backends.** Local and cloud transcription both produce the same `TranscriptResult` JSON schema. Everything downstream (speaker labeling, formatting, upload, display) is identical regardless of where transcription ran.

2. **AudioCaptureKit already gives us channel separation.** Today it records stereo WAV: channel 1 = therapist mic, channel 2 = system audio (remote participants via video call). This is a massive advantage for diarization — for telehealth sessions, we get near-perfect speaker separation for free by treating channels as speaker sources.

3. **Transcription lives in `core/` (Rust).** Both platforms (Mac + Windows) need the same transcription logic. Per the Rust Decision Rule: "Will the other platform need this?" — yes. ASR, diarization, speaker matching, and transcript formatting all belong in `pablo-core`.

4. **Speaker enrollment is an embedding, not raw audio.** We store a float vector (speaker embedding), never the raw voice sample. This minimizes PHI exposure from the enrollment itself.

5. **Backend endpoint follows existing patterns.** The transcript upload endpoint lives at `/api/sessions/{id}/transcript` on the same backend that serves `/api/patients`. Same auth (Bearer token), same base URL.

---

## 3. Audio Recording: Channel Strategy

### Current State (AudioCaptureKit)

| Property | Value |
|----------|-------|
| Format | WAV, PCM |
| Sample rate | 48,000 Hz |
| Bit depth | 16-bit |
| Channels | 2 (stereo) |
| Channel 1 | Therapist microphone |
| Channel 2 | System audio (remote participants) |

### Why This Matters for Diarization

For **telehealth sessions** (the primary use case — video calls via Zoom, Teams, Google Meet):

- Channel 1 (mic) = therapist voice only
- Channel 2 (system) = remote participant(s) voice only

This means **channel-based speaker separation is trivial** — no ML-based diarization needed for the therapist vs. remote split. We just run ASR on each channel independently and label accordingly.

For **couples counseling over telehealth**, both partners are on the remote end (channel 2). We need ML diarization only on channel 2 to separate Client A from Client B. This is a 2-speaker diarization problem on a single channel — much easier than 3-speaker on a mixed signal.

For **in-person sessions** (single mic, everyone in the room): both/all speakers are on channel 1. We need full diarization on the mixed signal. This is the hardest case but also the least common for telehealth-first therapists.

### Proposed AudioCaptureKit Changes

| Change | Rationale |
|--------|-----------|
| Expose per-channel audio buffers via delegate callback | Allows the transcription pipeline to process channels independently without re-demuxing the WAV |
| Add optional channel metadata to `RecordingResult` | Tag which channel is mic vs. system so downstream doesn't have to assume |
| Support configurable channel count (2, 3, 4) | Future-proofing for multi-mic setups (e.g., conference mic per seat) |
| Add raw PCM export option (alongside WAV) | Some ASR engines (whisper.cpp) prefer raw PCM; avoids header parsing |

These are additive, non-breaking changes.

---

## 4. Transcription Engine

### Local Backend: Whisper via whisper.cpp

**Why Whisper:**
- MIT-licensed (whisper.cpp), $0/minute marginal cost
- Strong accuracy on English conversational speech
- Runs fully offline — strongest HIPAA privacy story
- C/C++ implementation embeds cleanly in Rust via FFI (or as a subprocess)
- Metal acceleration on Apple Silicon, CPU fallback on Intel/Windows

**Model tiers (user-selectable):**

| Preset | Whisper Model | RAM Needed | Accuracy | Speed (1hr audio) |
|--------|--------------|------------|----------|-------------------|
| Fast | `small` (quantized) | ~2 GB | Good | ~15–30 min (Apple Silicon) |
| Balanced (default) | `small` | ~2 GB | Good+ | ~20–40 min |
| High Accuracy | `medium` (quantized) | ~5 GB | Very good | ~40–80 min |

**Hardware requirements (batch, after-session):**

| Tier | CPU | RAM | Storage |
|------|-----|-----|---------|
| Minimum | 4-core (M1 / Intel 10th gen+) | 8 GB | 5 GB free |
| Recommended | 6+ cores (M1 Pro / i7+) | 16 GB | 10 GB free |
| Best | M2 Pro+ / modern i9 | 32 GB | 15 GB free |

**Model distribution:** Download on first use (not bundled in installer). Models are cached locally in `~/Library/Application Support/PabloCompanion/Models/`. Encrypted at rest using the existing per-device AES-256-GCM key from Keychain.

### Cloud Backend: Pablo API

For users/orgs that prefer cloud processing:

1. Client uploads encrypted audio to `POST /api/sessions/{id}/audio`
2. Backend runs transcription (heavier models, GPU, better diarization)
3. Backend stores transcript, returns `TranscriptResult`
4. Audio is deleted after processing (configurable TTL, default: 24 hours)

Cloud backend can run Whisper large + heavier diarization models on GPU infrastructure. Same output schema.

---

## 5. Diarization Pipeline

### Overview

```
Audio (WAV) ──▶ Channel Splitter ──▶ Per-Channel Pipeline ──▶ Merge ──▶ Speaker Labeling
                                          │
                                          ▼
                                    ┌──────────┐
                                    │ 1. VAD    │  Voice Activity Detection
                                    │ 2. ASR    │  Whisper transcription
                                    │ 3. Embed  │  Speaker embedding extraction
                                    │ 4. Cluster│  Group segments by speaker
                                    │ 5. Merge  │  Combine adjacent same-speaker segments
                                    └──────────┘
```

### Step-by-Step

#### Step 1: Channel Splitting

Split the stereo WAV into separate mono streams:
- **Channel 1 (mic):** Therapist audio
- **Channel 2 (system):** Remote participant(s) audio

For telehealth 1:1, this alone gives us perfect diarization — no ML needed.

#### Step 2: Voice Activity Detection (VAD)

Detect speech regions in each channel. Filter out silence, noise, music.

**Algorithm:** Silero VAD (small, fast, MIT-licensed ONNX model) or energy-based VAD as fallback.

Output: list of `(start_ms, end_ms)` speech segments per channel.

#### Step 3: ASR (Speech-to-Text)

Run Whisper on each speech segment (or the full channel, letting Whisper handle its own segmentation).

Output: list of `(start_ms, end_ms, text, confidence)` per channel.

#### Step 4: Speaker Embedding Extraction

For channels with multiple speakers (e.g., channel 2 in couples counseling, or single-channel in-person recording):

Extract a **speaker embedding** (fixed-length float vector) for each speech segment.

**Model:** ECAPA-TDNN (state-of-the-art speaker verification model)
- Architecture: 1D-CNN + channel/spatial attention + multi-scale aggregation + ASP (attentive statistical pooling)
- Output: 192-dimensional embedding vector
- Trained on VoxCeleb1+2 (~7,000 speakers)
- Available as ONNX for cross-platform inference

**How it works (for the ML engineer):**

```
Audio segment (1-10s)
    │
    ▼
Mel-spectrogram (80 bands, 25ms frames, 10ms hop)
    │
    ▼
ECAPA-TDNN encoder
    │  - SE-Res2Block layers (multi-scale 1D convolutions)
    │  - Squeeze-and-excitation channel attention
    │  - Res2Net-style multi-scale feature aggregation
    │
    ▼
Attentive Statistical Pooling (ASP)
    │  - Attention weights over time frames
    │  - Weighted mean + weighted std concatenation
    │
    ▼
Linear projection → 192-dim embedding
    │
    ▼
L2 normalization → unit sphere
```

Each embedding captures the speaker's vocal characteristics (pitch, timbre, speaking rate, formant structure) in a compact vector where **cosine similarity** between same-speaker embeddings is high (~0.7–0.9) and between different speakers is low (~0.0–0.3).

#### Step 5: Clustering

Group speech segments by speaker using their embeddings.

**Algorithm:** Agglomerative Hierarchical Clustering (AHC) with cosine distance.

```
1. Start: each segment is its own cluster
2. Compute pairwise cosine distances between cluster centroids
3. Merge the two closest clusters
4. Repeat until distance threshold exceeded (or target # of clusters reached)
5. Output: cluster assignments (Speaker 0, Speaker 1, ...)
```

**Parameters:**
- Distance metric: cosine distance (1 - cosine_similarity)
- Linkage: average linkage
- Stopping threshold: 0.35–0.50 (tune on validation set)
- Optional: set `num_clusters` directly if session type is known (2 for 1:1, 3 for couples)

**Alternative:** Spectral clustering (better for non-convex clusters but slower). Use AHC as default; spectral as fallback for difficult cases.

#### Step 6: Turn Merging

Merge adjacent segments from the same speaker into readable "turns":

```
Merge when:
  - Same speaker AND
  - Gap between segments ≤ 1.0s AND
  - Combined duration ≤ 30s

Split when:
  - Pause ≥ 3.0s (even if same speaker)
  - Speaker changes
```

Output: list of turns `(start_ms, end_ms, speaker_id, text)`.

---

## 6. Speaker Labeling (Enrollment + Matching)

### Therapist Enrollment

During onboarding (or in Settings), the therapist records a 15–60 second voice sample. We:

1. Extract ECAPA-TDNN embedding from the sample
2. Store **only the embedding vector** (not the audio) — encrypted in Keychain (macOS) or Windows Credential Manager
3. Optionally store a backup embedding on the backend (encrypted at rest)

The raw audio is discarded immediately after embedding extraction.

### Per-Session Speaker Matching

After diarization produces speaker clusters, we match the therapist:

```
For each cluster centroid embedding:
    similarity = cosine_similarity(centroid, therapist_enrollment_embedding)

Best match (highest similarity, above threshold 0.65) → label "Therapist"
Remaining clusters → label "Patient" (for 1:1) or "Client A" / "Client B" (for couples)
```

### Couples: Labeling Client A vs Client B

Three options, in order of preference:

**Option 1 — Enrollment (best accuracy):**
Enroll both clients during their first session (therapist clicks "Enroll Client A" → record 15s of Client A speaking). Store embeddings per patient in the backend (linked to patient record). Future sessions auto-label.

**Option 2 — One-time manual mapping (simplest UX):**
After transcription, show the therapist 2–3 short audio snippets per unnamed speaker cluster. Therapist assigns: "This is Alex" / "This is Jordan." Save the mapping for this session. Optionally cache cluster centroids for future sessions with same participants.

**Option 3 — Hybrid (recommended for v1):**
Therapist is auto-labeled via enrollment. Remaining speakers are labeled "Client A" / "Client B" with a lightweight UI to rename them. If this is a recurring couple, cache the mapping by patient IDs.

### PLDA Scoring (Advanced, Phase 2)

For higher accuracy speaker identification (especially with noisy or short segments):

Replace raw cosine similarity with **Probabilistic Linear Discriminant Analysis (PLDA)**:

```
PLDA models:
  embedding = speaker_factor + channel_factor + noise

Scoring:
  score(e1, e2) = log P(e1, e2 | same speaker) / P(e1, e2 | different speakers)
```

PLDA learns a "within-speaker" vs "between-speaker" covariance model from training data. It's more robust than raw cosine when:
- Segments are short (< 3s)
- Recording conditions vary (different mics, rooms)
- Speaker characteristics are similar (e.g., two female voices)

For v1, cosine similarity is sufficient. Add PLDA in Phase 2 if accuracy needs improvement.

---

## 7. Overlap Handling (Couples)

Couples sessions have frequent interruptions and overlapping speech. This is the hardest part of couples diarization.

### Phase 1: Detection Only

Detect overlapping speech segments and tag them:

```
[OVERLAP 00:15:23–00:15:26]
Client A: I never said that—
Client B: —yes you did, last Tuesday
```

**Algorithm:** Train a small binary classifier on the audio features (energy, spectral flux) to detect multi-speaker regions. Or use a dedicated overlap detection model (e.g., from pyannote).

### Phase 2: Separation (Future)

Use a speech separation model (e.g., SepFormer, Conv-TasNet) to isolate individual speakers from overlapping audio, then transcribe each stream independently.

This is compute-heavy and is a future enhancement — not needed for v1.

---

## 8. Output Format

### Internal Canonical Schema

```json
{
  "session_id": "uuid",
  "recording_id": "uuid",
  "created_at": "2026-03-03T14:30:00Z",
  "duration_ms": 3600000,
  "processing": {
    "backend": "local",
    "asr_model": "whisper-small-q5",
    "diarization_model": "ecapa-tdnn-v1",
    "processing_time_ms": 1200000
  },
  "speakers": {
    "speaker_0": {
      "role": "THERAPIST",
      "display_name": "Dr. Lee",
      "patient_id": null,
      "enrollment_match_confidence": 0.87
    },
    "speaker_1": {
      "role": "CLIENT_A",
      "display_name": "Alex",
      "patient_id": "patient-uuid-123",
      "enrollment_match_confidence": null
    }
  },
  "segments": [
    {
      "start_ms": 12340,
      "end_ms": 18900,
      "speaker_id": "speaker_0",
      "text": "I want to check in on how the week has felt since our last session.",
      "confidence": 0.94,
      "channel": 1,
      "overlap": false
    },
    {
      "start_ms": 19200,
      "end_ms": 24100,
      "speaker_id": "speaker_1",
      "text": "It's been rough. I couldn't sleep much.",
      "confidence": 0.91,
      "channel": 2,
      "overlap": false
    }
  ],
  "warnings": [],
  "overlaps_detected": 0
}
```

### Google Meet-Style Rendering (for downstream)

The canonical schema is rendered into Meet-style transcript text before uploading to the backend:

```
00:00:12 Dr. Lee
I want to check in on how the week has felt since our last session.

00:00:19 Alex
It's been rough. I couldn't sleep much.

00:01:45 Dr. Lee
Can you tell me more about what's keeping you up?

00:01:52 Alex
I keep thinking about work. The layoffs. I don't know if I'm next.
```

**Formatting rules:**
- Timestamp per turn: `HH:MM:SS` (or `MM:SS` if session < 1 hour)
- Speaker display name on same line as timestamp
- Text on next line(s), wrapped naturally
- Blank line between turns
- `[OVERLAP]` tag for detected overlapping speech
- `[INAUDIBLE]` for low-confidence segments (confidence < 0.3)

---

## 9. Backend API

All endpoints follow existing patterns from `APIClient.swift`. Same base URL, same Bearer token auth, same `X-Client-Type` header.

### New Endpoints

#### `POST /api/sessions/{session_id}/transcript`

Upload a completed transcript for a session.

**Request body:** `TranscriptResult` JSON (the canonical schema from Section 8)

**Response:**
```json
{
  "id": "transcript-uuid",
  "session_id": "session-uuid",
  "status": "stored",
  "created_at": "2026-03-03T15:30:00Z"
}
```

#### `POST /api/sessions/{session_id}/audio` (cloud mode only)

Upload audio for server-side transcription.

**Request:** Multipart form-data (same pattern as existing `POST /api/recordings/upload`)

**Response:**
```json
{
  "job_id": "transcription-job-uuid",
  "status": "processing",
  "estimated_duration_s": 300
}
```

#### `GET /api/sessions/{session_id}/transcript`

Retrieve a stored transcript.

**Response:** `TranscriptResult` JSON

#### `GET /api/transcription-jobs/{job_id}`

Poll cloud transcription job status.

**Response:**
```json
{
  "job_id": "uuid",
  "status": "completed",
  "transcript_id": "transcript-uuid"
}
```

#### `POST /api/speaker-enrollments`

Store a speaker embedding for a user (therapist) or patient.

**Request:**
```json
{
  "patient_id": "patient-uuid-or-null",
  "embedding": [0.123, -0.456, ...],
  "embedding_model": "ecapa-tdnn-v1",
  "sample_duration_s": 30.0
}
```

**Response:**
```json
{
  "id": "enrollment-uuid",
  "status": "stored"
}
```

---

## 10. Code Architecture (Where Things Live)

### `core/` (Rust — pablo-core)

| Module | Responsibility |
|--------|---------------|
| `transcription.rs` | TranscriptionService trait + local/cloud backend selection |
| `whisper.rs` | whisper.cpp FFI bindings, model loading, inference |
| `diarization.rs` | VAD + speaker embedding + clustering pipeline |
| `speaker_matching.rs` | Enrollment storage, cosine similarity matching, label assignment |
| `transcript_formatter.rs` | Canonical schema → Meet-style text rendering |
| `models/transcript.rs` | `TranscriptResult`, `TranscriptSegment`, `SpeakerInfo` types |
| `api_client.rs` | (extend existing) transcript upload/download endpoints |

All transcription logic is cross-platform Rust. Both Mac and Windows call the same `pablo-core` functions via UniFFI.

### `mac/` (Swift — macOS app)

| File | Responsibility |
|------|---------------|
| `Services/TranscriptionService.swift` | Thin Swift wrapper calling pablo-core via UniFFI |
| `ViewModels/TranscriptionViewModel.swift` | UI state for transcription progress, model selection |
| `Views/TranscriptionSettingsView.swift` | Model tier picker, speaker count, local vs cloud toggle |
| `Views/SpeakerEnrollmentView.swift` | Record enrollment sample, show status |
| `Views/TranscriptReviewView.swift` | Show transcript, allow speaker renaming, confirm & upload |

### AudioCaptureKit Changes

| Change | File(s) |
|--------|---------|
| Per-channel buffer callback | `CompositeCaptureSession`, `AudioCaptureDelegate` |
| Channel metadata in `RecordingResult` | `RecordingResult.swift` |
| Raw PCM export option | `CaptureConfiguration` |

---

## 11. HIPAA Compliance

### What's PHI

| Data | PHI? | Where Stored |
|------|------|-------------|
| Audio recording (WAV) | Yes | Client device only (encrypted, AES-256-GCM). Uploaded to backend only in cloud mode (with TTL). |
| Transcript text | Yes | Backend (encrypted at rest, access-controlled). |
| Speaker embeddings | Maybe (biometric identifier) | Therapist: Keychain (local) + optional backend backup. Patient: backend (linked to patient record). |
| Speaker labels / names | Yes (linked to patient) | Backend (part of transcript). |
| Model files (Whisper, ECAPA) | No | Client device. Not PHI. |

### Controls

| Control | Implementation |
|---------|---------------|
| Encryption at rest | Audio: existing AES-256-GCM per-device key. Transcripts: backend DB encryption (KMS). Models: encrypted with device key. |
| Encryption in transit | TLS 1.2+ for all API calls (already enforced by `URLValidator`). |
| Access control | Bearer token auth (existing). Transcript access scoped to owning therapist's org. |
| Audit logging | Backend logs all transcript create/read/delete operations with user ID and timestamp. |
| Data retention | Audio on device: user-controlled deletion. Audio on backend (cloud mode): configurable TTL (default 24h, then auto-delete). Transcripts: retained until explicitly deleted by user or org policy. |
| Minimum necessary | Local mode: audio never leaves device. Embeddings stored, not raw voice samples. Only transcript text uploaded. |

---

## 12. Implementation Phases

### Phase 1: Foundation (v1)

**Deliverables:**
- [ ] Rust `pablo-core` crate initialized with transcription types
- [ ] whisper.cpp integration in Rust (FFI or subprocess)
- [ ] Channel-based speaker separation (mic vs system audio — no ML needed)
- [ ] ASR on each channel independently
- [ ] Turn merging + Meet-style transcript formatting
- [ ] Transcript upload to backend (`POST /api/sessions/{id}/transcript`)
- [ ] Backend endpoint for storing/retrieving transcripts
- [ ] Swift TranscriptionViewModel + basic progress UI
- [ ] Model download + caching (on first use)
- [ ] Transcription settings: model tier (Fast/Balanced/High Accuracy)

**Supports:** Telehealth 1:1 sessions (therapist mic + single remote participant). No ML diarization needed — channel separation handles it.

### Phase 2: Speaker Enrollment + Diarization

**Deliverables:**
- [ ] ECAPA-TDNN embedding extraction in Rust (ONNX runtime)
- [ ] Therapist voice enrollment (onboarding step)
- [ ] Cosine similarity matching for therapist identification
- [ ] AHC clustering for multi-speaker channels
- [ ] Couples counseling support (3 speakers)
- [ ] Speaker enrollment UI (SpeakerEnrollmentView)
- [ ] Transcript review UI with speaker renaming
- [ ] Backend endpoint for speaker enrollments
- [ ] AudioCaptureKit: per-channel buffer callback

**Supports:** Telehealth couples (1 mic channel + 2 remote speakers on system channel). In-person 1:1 and couples (all speakers on mic channel).

### Phase 3: Cloud Mode + Polish

**Deliverables:**
- [ ] Cloud transcription backend (Whisper large + GPU)
- [ ] Audio upload endpoint + job polling
- [ ] Local vs cloud toggle in settings (org-level override)
- [ ] Overlap detection and tagging
- [ ] PLDA scoring for more robust speaker matching
- [ ] Hardware auto-detection + recommended model tier
- [ ] Windows implementation (same Rust core via UniFFI/C#)

---

## 13. Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Whisper accuracy on clinical speech (therapy jargon, emotional speech, low volume) | Wrong words in clinical notes | Evaluate WER on therapy-like audio before shipping. Offer "High Accuracy" tier. Allow manual transcript correction UI. |
| Diarization errors in couples (similar voices, interruptions) | Wrong speaker attribution | Channel separation handles telehealth well. For in-person, overlap detection + manual review UI. Phase 2. |
| Large model files (~500MB–1.5GB) on therapist laptops | Slow first launch, disk space complaints | Download on demand, not bundled. Show download progress. Auto-detect storage and warn. |
| whisper.cpp / ONNX runtime stability across OS versions | Crashes, hangs during transcription | Run inference in a subprocess (crash isolation). Timeout + retry. Fallback to smaller model. |
| HIPAA: speaker embeddings as biometric identifiers | Regulatory exposure | Treat embeddings as PHI. Encrypt at rest. Allow deletion. Document in privacy policy. |
| Apple Silicon vs Intel performance gap | Intel Macs are slow | Default Intel to "Fast" tier (small model). Show estimated processing time. Recommend cloud mode for Intel. |

---

## 14. Open Questions

1. **Backend transcription endpoint:** Does the existing session model in `pablo` (backend) already have a transcript field, or do we need a new table/model? Need to check the `pablo` repo's session schema.

2. **AudioCaptureKit channel labeling:** Does the current `CompositeCaptureSession` already expose which channel is mic vs system in metadata, or do we need to add this?

3. **Model licensing for ECAPA-TDNN weights:** The architecture is open, but specific pretrained weights may have restrictions. Need to verify the license for the weights we ship (SpeechBrain VoxCeleb weights are Apache 2.0 — confirm).

4. **In-person recording setup:** For therapists who see patients in-office (not telehealth), do they use a single laptop mic? A conference mic? Multiple mics? This affects diarization difficulty. We should survey users.

5. **Transcript editing:** Do therapists need to correct transcription errors before the transcript is stored? If so, we need a transcript editor view (Phase 2/3).
