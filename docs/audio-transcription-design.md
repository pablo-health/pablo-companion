# Audio Transcription & Speaker Diarization — Design Document

_Created: 2026-03-03_
_Status: DRAFT — awaiting review_

---

## 1. Problem Statement

Pablo Companion records therapy sessions (audio) on the therapist's laptop. Today, those recordings are uploaded as raw audio to the Pablo backend. The backend (and downstream SOAP note generation) needs **text transcripts with speaker labels** in a structured format similar to Google Meet transcripts.

### Requirements

| Requirement | Detail |
|-------------|--------|
| **Transcription** | Speech-to-text from recorded WAV files |
| **Speaker diarization** | "Who said what" — label each segment by speaker |
| **Speaker identification** | Map diarized clusters to known roles: THERAPIST, CLIENT_A, CLIENT_B |
| **Session types** | 1:1 (therapist + patient) and couples counseling (therapist + 2 clients) |
| **HIPAA compliance** | PHI must be protected at rest, in transit, and during processing |
| **Processing mode** | Batch (after session ends) — not real-time |
| **Compute location** | Local-only (default) with optional cloud mode for quality/speed boost |
| **Output format** | Structured transcript matching Google Meet format (the downstream session pipeline expects this) |
| **Stereo playback** | System audio may be stereo; preserve stereo for human playback while processing mono for ASR |

### Non-Requirements (for this design)

- Real-time / live transcription during session
- Language translation
- Medical terminology custom dictionary (future enhancement)
- Windows support (design for it, implement later)

---

## 2. Architecture Overview

### Dual-Mode Design

```
┌─────────────────────────────────────────────────────────────┐
│  Pablo Companion (macOS / Windows)                          │
│                                                             │
│  ┌──────────┐   ┌──────────────┐   ┌────────────────────┐  │
│  │ Recording │──▶│ Audio Store  │──▶│ Transcription      │  │
│  │ Service   │   │ (encrypted   │   │ Pipeline           │  │
│  │           │   │  WAV on disk)│   │ (local or cloud)   │  │
│  └──────────┘   └──────────────┘   └────────┬───────────┘  │
│                                              │              │
│                              ┌───────────────▼──────────┐   │
│                              │ Transcript + Speaker Map │   │
│                              │ (canonical JSON schema)  │   │
│                              └───────────────┬──────────┘   │
│                                              │              │
│           ┌──────────────────────────────────▼──────────┐   │
│           │ Export: Google Meet format (for downstream)  │   │
│           └──────────────────────────────────┬──────────┘   │
│                                              │              │
└──────────────────────────────────────────────┼──────────────┘
                                               │
                                               ▼
                                     ┌──────────────────┐
                                     │ Pablo Backend    │
                                     │ (Python 3.13,   │
                                     │  Poetry, FastAPI)│
                                     │                  │
                                     │ Stores transcript│
                                     │ + SOAP pipeline  │
                                     └──────────────────┘
```

### Two Compute Backends, One Output Schema

| Mode | What happens | Audio leaves device? | PHI exposure |
|------|-------------|---------------------|--------------|
| **Local** (default) | Whisper + diarization run on therapist's laptop | No | Minimal — transcript uploaded to backend only |
| **Cloud** | Audio uploaded to Pablo backend; backend runs ASR + diarization; returns transcript | Yes (encrypted, to your infra) | Backend handles audio PHI (already HIPAA-scoped since backend stores transcripts) |

Both modes produce the same canonical JSON → the rest of the product doesn't care which ran.

---

## 3. Recording: Multi-Channel Strategy

### Current State

`RecordingService.swift` uses AudioCaptureKit with `CaptureConfiguration`:
- 48 kHz, 16-bit, **2-channel stereo** WAV
- Mic + system audio captured via `CompositeCaptureSession`

### Proposed Channel Layout

Record a **3-channel WAV** (or 2 separate files — see trade-offs below):

| Channel | Source | Purpose |
|---------|--------|---------|
| **Ch 1** | Local microphone | Therapist's voice (dominant) |
| **Ch 2** | System audio — left | Remote participant(s) — stereo preserved for playback |
| **Ch 3** | System audio — right | Remote participant(s) — stereo preserved for playback |

**Why this matters:**

- **Ch 1 is the therapist.** No enrollment or diarization needed for role labeling — channel identity = speaker identity.
- **Ch 2+3 contain only remote participants.** Diarization only needs to separate clients on the system audio channels — much easier than diarizing 3 voices from one mixed signal.
- **Stereo system audio preserved for playback.** When a therapist replays the session, they hear natural stereo. When ASR processes it, we downmix Ch 2+3 to mono first.

### Stereo Playback Optimization

```
Storage (WAV on disk):
  Ch 1: Mic (mono)        — therapist
  Ch 2: System Left        — clients, stereo L
  Ch 3: System Right       — clients, stereo R

For human playback → mix to stereo:
  L = Ch1 * 0.5 + Ch2 * 0.7    (therapist centered, clients in stereo)
  R = Ch1 * 0.5 + Ch3 * 0.7

For ASR processing → split to 2 mono streams:
  Stream A = Ch 1 (therapist)   → transcribe directly, label THERAPIST
  Stream B = (Ch 2 + Ch 3) / 2  → mono downmix, run diarization for CLIENT_A / CLIENT_B
```

This means:
- **Full stereo fidelity** preserved on disk for playback
- **Optimal mono** fed to ASR (Whisper performs best on mono 16 kHz)
- **Channel-based speaker separation** eliminates the hardest part of diarization (isolating therapist from clients)

### Alternative: 2-File Approach

Instead of a multi-channel WAV, store two files:
- `session_<id>_mic.wav` — mono, mic only
- `session_<id>_system.wav` — stereo, system audio only

**Trade-offs:**

| Approach | Pros | Cons |
|----------|------|------|
| Multi-channel WAV | Single file, atomic, simpler upload | Needs channel-aware playback; some tools choke on 3-ch WAV |
| 2 separate files | Each file is standard mono/stereo; easy to process | Must keep files in sync; two uploads; two encryptions |

**Recommendation:** Start with **2 separate files**. It's simpler to implement, every tool understands mono/stereo WAV, and the ASR pipeline can process them independently without demuxing. Combine them for playback in the UI with a lightweight mixer.

### Recording Library Decision

AudioCaptureKit is currently integrated but we're open to replacing it. The key capability needed is **separate mic and system audio streams**. Options:

| Option | Separate streams? | Effort | Notes |
|--------|-------------------|--------|-------|
| AudioCaptureKit (current) | Yes — mic + system via CompositeCaptureSession | Low (already integrated) | Verify it can output separate files or separate channel data |
| ScreenCaptureKit + AVAudioEngine (custom) | Yes — SCStream for system, AVAudioEngine for mic | Medium | More control, no external dependency |
| Replace with custom CoreAudio / AVFoundation | Yes — full control | High | Only if AudioCaptureKit is limiting |

**Recommendation:** Keep AudioCaptureKit if it supports writing separate mic/system streams. If not, wrap ScreenCaptureKit + AVAudioEngine — it's well-documented for macOS 14+ and gives full control over channel routing.

---

## 4. Transcription Pipeline (Local Mode)

### ASR: Whisper via whisper.cpp

**Why whisper.cpp:**
- MIT-licensed C/C++ implementation — no Python runtime needed
- Runs fully offline — no network calls, no vendor BAA needed
- First-class Apple Silicon support via Metal (GPU acceleration)
- GGML quantized models — small disk footprint, fast inference
- Rust bindings available via `whisper-rs` crate (if we go Rust core) or callable from Swift via C FFI

**Model selection — user-configurable "Speed vs Accuracy" preset:**

| Preset | Model | Disk Size (Q5_1) | RAM Usage | ~Speed on M1 (1hr audio) | WER (English) |
|--------|-------|-------------------|-----------|--------------------------|---------------|
| **Fast** | `whisper-small` | ~200 MB | ~1 GB | ~5–10 min | ~5–7% |
| **Balanced** (default) | `whisper-medium` | ~500 MB | ~2 GB | ~15–25 min | ~4–5% |
| **High Accuracy** | `whisper-large-v3` | ~1 GB | ~3–4 GB | ~30–50 min | ~3–4% |

All times are approximate for batch processing on Apple M1/M2. Intel Macs will be 2–4x slower; consider offering only Fast/Balanced on Intel.

**Quantization:** Use GGML Q5_1 format. Good accuracy-to-size tradeoff; Metal-accelerated on Apple Silicon.

**Key parameters for clinical audio:**
- `language = "en"` (or auto-detect; set explicitly to avoid wasted compute)
- `beam_size = 5` (default; good for accuracy without huge cost)
- `word_timestamps = true` (needed for diarization alignment)
- Input: **16 kHz mono PCM** (resample from 48 kHz before feeding to Whisper)

### Speaker Diarization

Since we have channel-separated audio, diarization is dramatically simpler:

**Channel 1 (mic = therapist):** No diarization needed. All speech on this channel is labeled `THERAPIST`.

**Channel 2 (system audio = remote participants):** This is where diarization matters.

#### For 1:1 Sessions (therapist + 1 client)

No diarization needed on system audio either — all speech on the system channel is the single client. Label it `CLIENT`.

#### For Couples Counseling (therapist + 2 clients)

Run diarization on the system audio mono downmix to separate 2 speakers.

**Pipeline:**

```
System audio (mono) ──▶ VAD ──▶ Speaker Embedding ──▶ Clustering ──▶ CLIENT_A / CLIENT_B
```

**Components:**

| Step | Algorithm | Implementation |
|------|-----------|----------------|
| **VAD** (voice activity detection) | Silero VAD | ONNX model, ~2 MB, runs anywhere, very fast |
| **Speaker embedding** | ECAPA-TDNN (SpeechBrain or pyannote pretrained) | 192-dim or 512-dim embeddings per segment |
| **Clustering** | Agglomerative Hierarchical Clustering (AHC) | Cosine distance, threshold tuned for 2-speaker case |
| **Smoothing** | Median filter on speaker labels | Remove rapid speaker switches (< 0.3s segments) |

**Why not pyannote.audio end-to-end?**
- pyannote's pretrained pipeline is excellent but requires Python + PyTorch
- Model weights require accepting terms on Hugging Face (licensing friction for shipping in a desktop app)
- For our constrained case (only 2 speakers on the system audio channel), a simpler pipeline with ONNX models is lighter, faster, and easier to package

**Why not a Rust-native solution?**
- No mature Rust diarization library exists today
- Best path: use ONNX Runtime (has Rust bindings via `ort` crate) to run VAD + embedding models
- Or: call whisper.cpp + ONNX models from Swift directly via C FFI (avoids Python entirely)

### Speaker Enrollment & Identification

For **couples counseling**, we need to tell CLIENT_A from CLIENT_B consistently across sessions.

#### Enrollment Flow

1. **Therapist enrollment (one-time, during onboarding):**
   - Record 15–30 seconds of therapist speaking
   - Extract ECAPA-TDNN embedding → store as `therapist_voiceprint` (192-dim float vector, ~768 bytes)
   - This is a backup/verification — primary labeling comes from channel separation
   - **Important:** Store only the embedding vector, never raw enrollment audio (minimizes PHI)

2. **Client enrollment (per couple, optional but recommended):**
   - First session: after diarization produces 2 clusters, play 2–3 short clips from each
   - Therapist labels: "This is Alex" / "This is Jordan"
   - Extract centroid embedding for each client → store per-patient record
   - Subsequent sessions: auto-match diarized clusters to stored embeddings via cosine similarity

3. **No-enrollment fallback:**
   - Diarize into 2 clusters
   - Label as `CLIENT_A` / `CLIENT_B` (generic)
   - Therapist can rename in the transcript editor UI

#### Matching Algorithm

```
For each diarized speaker cluster C:
    centroid_embedding = mean(segment_embeddings in C)
    for each enrolled_speaker S:
        score = cosine_similarity(centroid_embedding, S.embedding)
    assign C → argmax(score) if score > threshold (0.5–0.7)
    else → UNKNOWN
```

**Threshold tuning:** Start at 0.6, validate on test recordings with known speakers. Voice changes (colds, emotional state, different mic) can lower similarity — the threshold should be conservative with a "confirm" UX fallback.

#### Embedding Storage

| What | Where | Size | PHI? |
|------|-------|------|------|
| Therapist voiceprint | Keychain (macOS) or encrypted local DB | ~768 bytes | Biometric-adjacent — treat as sensitive |
| Client voiceprints | Encrypted local DB, keyed by patient ID | ~768 bytes each | Yes — biometric identifier under HIPAA |
| Raw enrollment audio | **Never stored** — process and discard | N/A | N/A |

---

## 5. Transcription Pipeline (Cloud Mode)

When the therapist (or their org) opts into cloud processing:

### Upload Flow

```
Companion App                          Pablo Backend (Python 3.13 / FastAPI)
─────────────                          ────────────────────────────────────

1. Session ends
2. Encrypt audio (AES-256)
3. Upload encrypted audio    ────────▶ 4. Receive + store encrypted audio
   via POST /api/transcription/jobs       (temp storage, short TTL)
                                       5. Decrypt in secure worker
                                       6. Run Whisper (faster-whisper / GPU)
                                       7. Run diarization (pyannote / NeMo)
                                       8. Speaker enrollment matching
                                       9. Build canonical transcript JSON
                                       10. Store transcript (long-term)
                                       11. Delete audio (per retention policy)
12. Poll / receive webhook   ◀──────── 12. Return transcript via API
13. Display transcript
```

### Backend Stack (Python 3.13 / Poetry)

| Component | Library | Why |
|-----------|---------|-----|
| **ASR** | `faster-whisper` (CTranslate2 backend) | 4x faster than OpenAI Whisper, GPU support, Python-native |
| **Diarization** | `pyannote.audio` 3.x | Best open-source diarization; full pipeline with overlap handling |
| **Speaker embeddings** | `speechbrain` ECAPA-TDNN or pyannote's built-in | Same embedding space as local mode for cross-mode consistency |
| **VAD** | `pyannote.audio` built-in (or Silero) | Integrated with diarization pipeline |
| **GPU** | CUDA via PyTorch | Much faster than CPU for large models |

**Why the backend can use heavier tools:**
- No packaging constraints (no need to ship models inside an app bundle)
- GPU available (unlike most therapist laptops)
- Python ecosystem is richer for ML (pyannote, faster-whisper, etc.)
- Can run `whisper-large-v3` + full pyannote pipeline with overlap detection

### Backend API Endpoints (New)

```
POST   /api/transcription/jobs           # Submit audio for transcription
GET    /api/transcription/jobs/{id}      # Poll job status
GET    /api/transcription/jobs/{id}/result  # Get transcript
DELETE /api/transcription/jobs/{id}      # Cancel / delete

POST   /api/speakers/enroll              # Upload enrollment embedding
GET    /api/speakers/{patient_id}        # Get stored voiceprint
```

### Audio Retention Policy

| Setting | Default | Configurable? |
|---------|---------|---------------|
| Audio retention after transcription | **Delete within 24 hours** | Yes — org-level setting |
| Transcript retention | **Indefinite** (until patient/session deleted) | Yes — org-level |
| Failed job audio retention | Delete within 72 hours | Yes |

---

## 6. Canonical Output Schema

Both local and cloud modes produce the same JSON:

```json
{
  "schema_version": "1.0",
  "session_id": "uuid",
  "created_at": "2026-03-03T14:30:00Z",
  "duration_seconds": 3420,
  "processing": {
    "mode": "local",
    "asr_model": "whisper-small-q5_1",
    "diarization_model": "ecapa-tdnn-silero-vad",
    "processing_time_seconds": 312
  },
  "speakers": {
    "SPK_0": {
      "role": "THERAPIST",
      "display_name": "Dr. Lee",
      "enrollment_match_confidence": 0.92
    },
    "SPK_1": {
      "role": "CLIENT_A",
      "display_name": "Alex",
      "enrollment_match_confidence": 0.87
    },
    "SPK_2": {
      "role": "CLIENT_B",
      "display_name": "Jordan",
      "enrollment_match_confidence": null
    }
  },
  "segments": [
    {
      "start": 0.0,
      "end": 4.52,
      "speaker": "SPK_0",
      "text": "Good afternoon. How has the week been since we last met?",
      "confidence": 0.94,
      "words": [
        {"word": "Good", "start": 0.0, "end": 0.3, "confidence": 0.98},
        {"word": "afternoon.", "start": 0.3, "end": 0.8, "confidence": 0.96}
      ]
    },
    {
      "start": 4.80,
      "end": 12.34,
      "speaker": "SPK_1",
      "text": "It's been rough. I couldn't sleep much this week.",
      "confidence": 0.91,
      "overlap": false
    }
  ],
  "metadata": {
    "audio_channels_recorded": 3,
    "sample_rate": 48000,
    "overlap_segments_detected": 2,
    "total_speech_duration_seconds": 2890,
    "silence_duration_seconds": 530
  }
}
```

### Google Meet Format Export

The downstream session pipeline expects a Google Meet–style transcript. Render from canonical JSON:

```
00:00:00 Dr. Lee
Good afternoon. How has the week been since we last met?

00:00:04 Alex
It's been rough. I couldn't sleep much this week.

00:00:12 Jordan
I noticed that too. There's been a lot of tension at home.

00:00:23 Dr. Lee
Can you both tell me more about what's been creating that tension?
```

**Rendering rules:**
- Timestamp: `HH:MM:SS` at turn-level (start of first segment in the turn)
- Speaker: `display_name` from speaker map
- Merge adjacent segments from same speaker if gap ≤ 1.5 seconds
- Start new turn if: speaker changes, OR pause > 3 seconds (even if same speaker)
- Overlap: tag `[overlapping]` inline if `overlap: true` (optional, depends on downstream needs)

---

## 7. User-Facing Settings

### Transcription Settings (in Settings tab)

| Setting | Options | Default | Notes |
|---------|---------|---------|-------|
| **Processing mode** | Local / Cloud | Local | Org-level override possible |
| **Quality preset** | Fast / Balanced / High Accuracy | Balanced | Maps to Whisper model size |
| **Session type** | 1:1 / Couples | 1:1 | Affects diarization (2 vs 3 speakers) |
| **Auto-transcribe** | On / Off | On | Start transcription automatically when recording stops |
| **Speaker enrollment** | Manage voiceprints | — | Enroll therapist, view/delete client voiceprints |

### Hardware Detection & Guardrails

On app launch, detect:
- CPU type (Apple Silicon vs Intel)
- Available RAM
- GPU capabilities (Metal support)

Show warnings:
- "High Accuracy requires 16+ GB RAM" (if < 16 GB and user picks High Accuracy)
- "Transcription may be slow on this Mac. Consider Cloud mode." (if Intel + < 16 GB)
- Auto-select "Fast" on low-spec machines

### Model Management

| Strategy | Description |
|----------|-------------|
| **Bundled default** | Ship `whisper-small` (Q5_1, ~200 MB) in the app bundle |
| **On-demand download** | Offer Medium and Large as optional downloads from Pablo CDN |
| **Model cache** | Store in `~/Library/Application Support/PabloCompanion/Models/` |
| **Updates** | Check for model updates on app launch (background, non-blocking) |

Diarization models (Silero VAD ~2 MB, ECAPA-TDNN ~20 MB) are small enough to always bundle.

---

## 8. HIPAA Considerations

### On-Device (Local Mode)

| Concern | Mitigation |
|---------|-----------|
| Audio files at rest | AES-256 encryption (already implemented in `RecordingEncryptor`) |
| Transcript at rest (before upload) | Encrypt with same device key |
| Temp files during ASR | Use secure temp directory; wipe on completion |
| Model files | Not PHI (pretrained, no patient data) |
| Voiceprint embeddings | Biometric identifier — encrypt, store in Keychain or encrypted DB |
| Processing in RAM | Standard — no special mitigation needed (RAM is volatile) |
| Audio never leaves device | Strongest privacy posture — document for customers |

### Cloud Mode (Backend)

| Concern | Mitigation |
|---------|-----------|
| Audio in transit | TLS 1.3 + application-layer AES-256 encryption |
| Audio at rest on server | Encrypted (KMS-managed keys); short TTL (default: delete after 24h) |
| Transcript at rest | Encrypted; long-term storage per retention policy |
| Access controls | Per-tenant isolation; role-based access; audit logging |
| Voiceprints on server | Encrypted; access-controlled; deletion on patient removal |
| Worker process | Isolated container; no persistent state; logs scrubbed of PHI |
| BAA | Pablo backend already handles PHI (patient data, session data) — same BAA scope |
| Subprocessors | No external ASR vendors — self-hosted models only |

### Voiceprint-Specific HIPAA Note

Speaker embeddings are **biometric identifiers** and qualify as PHI under HIPAA. Treat them with the same controls as any other patient identifier:
- Encrypt at rest
- Include in data deletion workflows (when patient is removed)
- Audit access
- Include in breach notification scope
- Do NOT use for any purpose other than speaker identification in transcription

---

## 9. Implementation Architecture (Where Code Lives)

Following the Rust Decision Rule from CLAUDE.md: "Will the other platform need this?"

### In `core/` (Rust) — Cross-Platform Logic

| Component | Why Rust |
|-----------|----------|
| Transcript schema types (`TranscriptResult`, `Segment`, `SpeakerMap`) | Both platforms need identical types |
| Whisper wrapper (via `whisper-rs` or C FFI to `whisper.cpp`) | ASR must behave identically |
| Diarization pipeline (ONNX Runtime via `ort` crate) | Same models, same thresholds |
| Speaker enrollment matching (cosine similarity on embeddings) | Cross-platform consistency |
| Audio preprocessing (resample 48→16 kHz, channel split, mono downmix) | Deterministic processing |
| Google Meet format renderer | Consistent output |
| Transcription job orchestrator (coordinate ASR → diarization → merge → export) | Business logic |

### Stays Native (Swift for mac/)

| Component | Why native |
|-----------|-----------|
| Audio recording (AudioCaptureKit / ScreenCaptureKit) | Platform audio APIs |
| Voiceprint storage (Keychain) | Platform credential storage |
| Model file management (download, cache, disk space) | Platform file system |
| UI (settings, transcript viewer, enrollment flow) | SwiftUI |
| Hardware detection (RAM, CPU, GPU) | Platform APIs |

### Backend (Python 3.13 / FastAPI)

| Component | Library |
|-----------|---------|
| Cloud transcription worker | `faster-whisper` + `pyannote.audio` |
| Transcription job API | FastAPI endpoints |
| Speaker enrollment storage | PostgreSQL (encrypted column) |
| Audio temp storage | S3-compatible with lifecycle policy |

---

## 10. Phased Implementation Plan

### Phase 1: Local Transcription MVP

**Goal:** Therapist records → app transcribes locally → uploads transcript to backend

- [ ] Audio preprocessing in Rust: resample, channel split, mono downmix
- [ ] Integrate `whisper.cpp` via `whisper-rs` in `core/`
- [ ] Basic diarization: channel-based only (Ch 1 = therapist, Ch 2 = client)
- [ ] Canonical JSON output
- [ ] Google Meet format export
- [ ] New API endpoint: `POST /api/sessions/{id}/transcript`
- [ ] Backend stores transcript
- [ ] Settings UI: quality preset, auto-transcribe toggle
- [ ] Model bundling (ship `whisper-small` in app)

### Phase 2: Couples Counseling + Speaker Enrollment

**Goal:** Support 3 speakers with enrollment-based labeling

- [ ] Speaker embedding extraction (ECAPA-TDNN via ONNX)
- [ ] 2-speaker diarization on system audio channel
- [ ] Therapist enrollment flow (onboarding)
- [ ] Client enrollment flow ("name the speakers" UI)
- [ ] Cosine similarity matching for returning clients
- [ ] Voiceprint encrypted storage (Keychain + backend)
- [ ] Session type setting (1:1 vs couples)

### Phase 3: Cloud Mode

**Goal:** Optional server-side transcription for speed/quality

- [ ] Backend transcription worker (`faster-whisper` + `pyannote.audio`)
- [ ] Transcription job API (submit, poll, result, delete)
- [ ] Client-side: encrypted upload, job polling, transcript download
- [ ] Audio retention policy (configurable TTL)
- [ ] Org-level cloud mode toggle
- [ ] Quality comparison tooling (local vs cloud on same audio)

### Phase 4: Refinements

**Goal:** Polish, edge cases, quality improvements

- [ ] Overlap detection and labeling
- [ ] Hardware-adaptive quality preset auto-selection
- [ ] On-demand model download (Medium, Large)
- [ ] Transcript editor UI (correct speaker labels, fix ASR errors)
- [ ] Feedback loop: therapist corrections → track WER over time
- [ ] Intel Mac optimization (or "cloud recommended" nudge)

---

## 11. Key Technical Decisions Still Needed

| Decision | Options | Recommendation | Impact |
|----------|---------|----------------|--------|
| **Recording: 1 file vs 2 files** | Multi-channel WAV vs separate mic/system files | 2 separate files | Simpler tooling, no 3-channel WAV compat issues |
| **Recording library** | Keep AudioCaptureKit vs replace | Keep if it supports separate streams; else ScreenCaptureKit + AVAudioEngine | Low effort either way |
| **Whisper integration** | `whisper-rs` (Rust) vs Swift C FFI to `whisper.cpp` | `whisper-rs` in core/ — keeps business logic in Rust | Affects Rust core timeline |
| **Diarization runtime** | ONNX via `ort` (Rust) vs Python subprocess vs Swift ONNX | ONNX via `ort` in Rust core | Best for cross-platform |
| **Embedding model** | ECAPA-TDNN (SpeechBrain) vs pyannote's segmentation model | ECAPA-TDNN (well-understood, ONNX-exportable, 192-dim) | Affects enrollment storage |
| **Cloud diarization** | `pyannote.audio` vs NVIDIA NeMo | `pyannote.audio` (better community, overlap support) | Backend only |
| **Voiceprint storage location** | Keychain only vs encrypted SQLite vs backend | Keychain for therapist; encrypted local DB + backend for clients | Affects sync story |
| **Model distribution** | Bundle in app vs download on first use | Bundle small; download medium/large on demand | Affects app size (~200 MB for small) |

---

## 12. Open Questions

1. **Does AudioCaptureKit's `CompositeCaptureSession` support writing mic and system audio to separate files (or separate channel buffers)?** If not, we need to replace or extend it.

2. **What's the exact Google Meet transcript format the downstream pipeline expects?** Is it plain text (as shown above), DOCX, VTT/SRT, or JSON? Need to match precisely.

3. **Org-level settings for cloud mode** — does the Pablo backend already have an org/tenant settings model, or do we need to build one?

4. **pyannote model licensing** — the pretrained models require accepting terms on Hugging Face. For the backend this is fine (one-time acceptance). For client-side ONNX exports, verify redistribution rights.

5. **Enrollment consent** — recording a voiceprint is biometric data collection. Do we need explicit consent UI beyond HIPAA? (State laws like BIPA in Illinois require it.)

6. **Whisper model updates** — how do we ship updated/improved models to existing installs? Silent background download + version check?

---

## 13. Glossary

| Term | Definition |
|------|-----------|
| **ASR** | Automatic Speech Recognition — converting audio to text |
| **Diarization** | Determining "who spoke when" in a multi-speaker recording |
| **Speaker enrollment** | Recording a voice sample to create a reusable speaker identity |
| **Voiceprint / embedding** | A compact numerical vector representing a speaker's voice characteristics |
| **ECAPA-TDNN** | A neural network architecture for extracting speaker embeddings |
| **VAD** | Voice Activity Detection — finding speech vs silence in audio |
| **WER** | Word Error Rate — percentage of incorrectly transcribed words |
| **DER** | Diarization Error Rate — percentage of incorrectly attributed speaker time |
| **GGML** | A tensor library / model format used by whisper.cpp for quantized models |
| **ONNX** | Open Neural Network Exchange — portable model format for inference |
| **PHI** | Protected Health Information — any health data identifiable to a patient |
| **BAA** | Business Associate Agreement — HIPAA contract for vendors handling PHI |
| **BIPA** | Biometric Information Privacy Act — Illinois state law on biometric data |
