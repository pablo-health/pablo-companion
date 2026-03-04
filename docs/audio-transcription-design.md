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
- 48 kHz, 16-bit, 2-channel stereo WAV
- Mic + system audio currently mixed into a single file via `CompositeCaptureSession`

### Approach: AudioCaptureKit Separate Streams

AudioCaptureKit is a first-party Pablo framework (not a third-party dependency). We will **extend its API** to support separate output files per stream. AudioCaptureKit's responsibility is simply to capture at the best quality it can and write separate files — it does not resample, mix, or do any ML processing. All downstream audio processing (resampling for ASR, playback mixing) is the Rust core's job.

**Two output files:**

| File | Channels | Format | Contains |
|------|----------|--------|---------|
| `*_mic.wav` | 1 (mono) | 48 kHz, 16-bit PCM | Microphone only — therapist's voice |
| `*_system.wav` | 2 (stereo) | 48 kHz, 16-bit PCM | System/loopback audio only — remote participant(s) |

**Why this is the right model:**
- **Mic file = therapist.** Channel identity replaces speaker diarization for the primary speaker — no embedding, no clustering needed to label the therapist.
- **System file = client(s).** Diarization only needs to separate speakers within the client audio, which is dramatically simpler (2 speakers on one channel vs 3 on a mixed channel).
- **Stereo preserved for playback.** The system file is full stereo. When a therapist replays the session, the UI mixes both files for natural stereo playback. When the ASR pipeline processes the system file, it downmixes to mono first — that's a trivial operation in the Rust core.
- **Standard formats.** Mono WAV and stereo WAV are understood by every tool; no multi-channel exotic formats to deal with.

**See `docs/audiocapturekit-separate-streams-design.md`** for the full AudioCaptureKit API design — that doc is the implementation spec for the AudioCaptureKit team.

---

## 4. Transcription Pipeline (Local Mode)

### ASR: Whisper via whisper.cpp

**Why whisper.cpp:**
- MIT-licensed C/C++ implementation — no Python runtime needed
- Runs fully offline — no network calls, no vendor BAA needed
- First-class Apple Silicon support via Metal (GPU acceleration)
- GGML quantized models — small disk footprint, fast inference
- Rust bindings available via `whisper-rs` crate v0.15.1 (actively maintained, 7 releases in 2025, Unlicense) or callable from Swift via C FFI
- Memory profile stays flat regardless of audio length — critical for long therapy sessions
- CoreML + Metal achieves 8–12x faster than CPU-only on Apple Silicon (first run slower due to ANE compilation)

**Model selection — user-configurable "Speed vs Accuracy" preset:**

| Preset | Model | Params | Disk (Q5_0) | RAM | ~Speed on Apple Silicon (1hr audio) | WER (English) |
|--------|-------|--------|-------------|-----|-------------------------------------|---------------|
| **Fast** | `whisper-small` | 244M | ~200 MB | ~2 GB | ~5–10 min | ~5–7% |
| **Balanced** (default) | `whisper-large-v3-turbo` | 809M | ~1.0 GB | ~6 GB | ~6–10 min | ~3–4% |
| **High Accuracy** | `whisper-large-v3` | 1.55B | ~1.6 GB | ~10 GB | ~30–50 min | ~3% |

**Why large-v3-turbo is the Balanced default (not medium):** It's 8x faster than large-v3 with near-identical accuracy, and often faster than medium due to architectural optimizations. On an M2 MacBook, it transcribes 10 minutes of audio in ~63 seconds. It's the sweet spot for therapy sessions — near-best accuracy at fast speed. Note: it was not trained for translation tasks, but that's irrelevant for English therapy sessions.

All times are approximate for batch processing on Apple M1/M2+. Intel Macs will be 2–4x slower; consider offering only Fast on Intel or nudging toward Cloud mode.

**Quantization:** Use GGML Q5_0 format. Best accuracy-to-size tradeoff; Metal-accelerated on Apple Silicon. The Q5_0 large-v3-turbo is roughly 1.0 GB on disk.

**Key parameters for clinical audio:**
- `language = "en"` (or auto-detect; set explicitly to avoid wasted compute)
- `beam_size = 5` (default; good for accuracy without huge cost)
- `word_timestamps = true` (needed for diarization alignment)
- Input: **16 kHz mono PCM** (resample from 48 kHz before feeding to Whisper)

### Session Type Controls the Pipeline

The therapist flags the session type before (or at the start of) a session. This is the single biggest lever for reducing laptop footprint. The session type determines exactly which pipeline components run.

#### 1:1 Mode (default) — Zero Diarization

When session type is `1:1`, **no diarization pipeline is needed at all**:

```
Mic file   ──▶ Whisper ──▶ all segments labeled THERAPIST
System file ──▶ Whisper ──▶ all segments labeled CLIENT
                          ──▶ merge by timestamp ──▶ canonical JSON
```

- The Silero VAD and ECAPA-TDNN models are **never loaded**
- No embeddings, no clustering, no cosine matching
- Just two Whisper passes and a timestamp merge
- Whisper still uses word timestamps for clean turn segmentation

**Footprint in 1:1 mode:**

| Resource | Usage |
|----------|-------|
| Models on disk | Whisper only (~200 MB–1.6 GB depending on preset) |
| RAM during processing | Whisper model only (~1–6 GB) |
| Diarization models | Not loaded |
| Processing time | Two Whisper passes only — ~2× single-file time |
| PHI stored | None (no voiceprints, no embeddings) |

#### Couples Mode — Diarization on System Audio Only

When session type is `couples`, run diarization **only on the system audio file** to separate the 2 remote clients. The mic file still needs no diarization — it's always the therapist.

```
Mic file    ──▶ Whisper ──▶ all segments labeled THERAPIST
System file ──▶ Whisper (with word timestamps)
            ──▶ VAD + ECAPA-TDNN embeddings + AHC clustering
            ──▶ CLIENT_A / CLIENT_B labels
            ──▶ merge by timestamp ──▶ canonical JSON
```

**Diarization pipeline components (couples mode only):**

| Step | Algorithm | Implementation | Size |
|------|-----------|----------------|------|
| **VAD** | Silero VAD | ONNX via `ort` crate | ~2 MB |
| **Speaker embedding** | ECAPA-TDNN (`speechbrain/spkrec-ecapa-voxceleb`) | ONNX via `ort` crate | ~20 MB |
| **Clustering** | Agglomerative Hierarchical Clustering (AHC) | Pure Rust | — |
| **Smoothing** | Median filter on speaker labels | Pure Rust | — |

**Footprint in couples mode:**

| Resource | Usage |
|----------|-------|
| Extra models on disk | +~22 MB (Silero VAD + ECAPA-TDNN ONNX) |
| Extra RAM | +~100–200 MB when diarization models loaded |
| PHI stored | Client voiceprints (~768 bytes × 2) — couples clients only |

**Model loading strategy:** Load Silero VAD and ECAPA-TDNN **lazily**, only when a couples session is processed. Unload after processing. For therapists who never do couples work, these models are never touched.

**Why not pyannote.audio end-to-end on-device?**
- Requires Python + PyTorch runtime — not acceptable for a native desktop app
- For our constrained case (2 speakers on one channel), the lightweight ONNX pipeline is sufficient, faster, and easier to package
- pyannote community-1 is the right choice for cloud mode (backend) — best open-source accuracy, CC-BY-4.0, no gating

**Why not a Rust-native diarization library?**
- None exist today (confirmed via research)
- ONNX Runtime via the `ort` crate is the right bridge: production-ready, 3–5× faster than Python, 60–80% less memory, CoreML execution provider on macOS

### Speaker Enrollment & Identification

**Therapist enrollment is not needed.** The mic file is definitionally the therapist — channel identity replaces voiceprint matching entirely. This eliminates a class of PHI (biometric data) and a whole enrollment UX flow.

For **couples counseling** only, we need to tell CLIENT_A from CLIENT_B consistently across sessions. Both clients arrive on the same system audio channel, so we need to diarize and then label them persistently.

#### Enrollment Flow (Couples Only)

1. **First couples session — "name the speakers" UX:**
   - Run diarization on the system audio → produces 2 clusters (UNKNOWN_A, UNKNOWN_B)
   - Play 2–3 short clips from each cluster in the transcript editor UI
   - Therapist assigns names: "This is Alex" / "This is Jordan"
   - Extract centroid ECAPA-TDNN embedding for each cluster → store keyed by patient ID
   - Subsequent sessions: auto-match new clusters to stored embeddings via cosine similarity

2. **No-enrollment fallback (non-couples, or if therapist skips naming):**
   - System audio diarizes to `CLIENT_A` / `CLIENT_B` (generic labels)
   - Therapist can rename in the transcript editor UI at any time
   - No embedding stored — labels are manual only

#### Matching Algorithm

```
For each diarized speaker cluster C:
    centroid_embedding = mean(segment_embeddings in C)
    for each enrolled_speaker S:
        score = cosine_similarity(centroid_embedding, S.embedding)
    assign C → argmax(score) if score > threshold (0.25–0.35)
    else → UNKNOWN
```

**Why cosine similarity (not PLDA):** For large-margin trained embeddings like ECAPA-TDNN, cosine similarity performs as well as PLDA (confirmed by Wang et al., Interspeech 2022). PLDA adds complexity (requires training data, LDA dimension reduction) with minimal benefit for 192-dim embeddings. Cosine is simple, effective, and runs in microseconds.

**Threshold tuning:** Start at 0.30, validate on test recordings with known speakers. The ECAPA-TDNN cosine similarity range for same-speaker pairs is typically 0.5–0.9, and for different speakers 0.0–0.3. A threshold of 0.25–0.35 balances false accepts vs false rejects. Voice changes (colds, emotional state, different mic) can lower similarity — the threshold should be conservative with a "confirm" UX fallback.

#### Embedding Storage

| What | Where | Size | PHI? |
|------|-------|------|------|
| ~~Therapist voiceprint~~ | ~~Not needed~~ | — | Eliminated — mic channel = therapist by definition |
| Client voiceprints (couples only) | Encrypted local DB, keyed by patient ID + synced to backend | ~768 bytes each | Yes — biometric identifier under HIPAA |
| Raw enrollment audio | **Never stored** — process and discard immediately | N/A | N/A |

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
| **Diarization** | `pyannote.audio` 4.x (`community-1`, CC-BY-4.0) | Best open-source diarization; not gated; exclusive speaker mode; overlap handling |
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
    "recording_mode": "separate_files",
    "sample_rate": 48000,
    "overlap_segments_detected": 2,
    "total_speech_duration_seconds": 2890,
    "silence_duration_seconds": 530
  }
}
```

### Google Meet Format Export

The downstream session pipeline expects a Google Meet–style transcript. This format has been confirmed from real session data (see `meeting-transcription` repo synthetic samples).

**Exact format:**

```
Google Meet Transcript
Session Date: April 3, 2024
Duration: 52:14

[00:00:08]
Dr. James Rodriguez: Hey Marcus, good to see you. How have you been since our last session?

[00:00:13]
Marcus Williams: Hey Doc. I've been... it's been a rough week, honestly.

[00:00:18]
Dr. James Rodriguez: I'm sorry to hear that. Do you want to tell me what's been going on?

[Session ends 00:22:57]

---
Total Duration: 52:14
Speakers: 2
Dr. James Rodriguez (Therapist)
Marcus Williams (Client)
```

**Format specification:**
- Line 1: literal `Google Meet Transcript`
- Line 2: `Session Date: <Month D, YYYY>`
- Line 3: `Duration: <MM:SS or H:MM:SS>` (total session duration)
- Line 4: blank
- For each turn:
  - `[HH:MM:SS]` — timestamp on its own line (format: always 2-digit hours)
  - `Speaker Display Name: utterance text` — on the next line
  - Blank line after each turn
- Session end marker: `[Session ends HH:MM:SS]`
- Blank line
- `---` separator
- `Total Duration: <same as header Duration>`
- `Speakers: N`
- One line per speaker: `Display Name (Role)` — roles are: `Therapist`, `Client`, `Client - <description if relevant>`
- Blank line (no `Clinical Notes` section — that is added downstream by the SOAP note pipeline, not by us)

**Rendering rules from canonical JSON:**
- Timestamp: use `start` time of first segment in the turn, formatted as `[HH:MM:SS]`
- Speaker name: `display_name` from speaker map
- Merge adjacent segments from same speaker if gap ≤ 1.5 seconds → single turn
- Start new turn if: speaker changes, OR pause > 3 seconds within same speaker
- No inline overlap tags — if overlap detected, attribute to dominant speaker
- `Session Date` comes from session metadata (session scheduled date, not file creation date)
- `Duration` comes from canonical JSON `duration_seconds`

---

## 7. User-Facing Settings

### Transcription Settings (in Settings tab)

| Setting | Options | Default | Notes |
|---------|---------|---------|-------|
| **Processing mode** | Local / Cloud | Local | Can be overridden by system-level settings |
| **Quality preset** | Fast / Balanced / High Accuracy | Balanced | Maps to Whisper model size |
| **Session type** | 1:1 / Couples | 1:1 | **1:1 = no diarization at all** (smallest footprint). Couples = VAD + ECAPA-TDNN loaded on demand. |
| **Auto-transcribe** | On / Off | On | Start transcription automatically when recording stops |
| **Speaker enrollment** | Manage voiceprints | — | View/delete client voiceprints for couples sessions (no therapist enrollment needed) |

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
| **Bundled default** | Ship `whisper-large-v3-turbo` (Q5_0, ~1.0 GB) in the app bundle — it's the best speed/accuracy tradeoff |
| **Lightweight fallback** | Ship `whisper-small` (~200 MB) as the "Fast" option, also bundled |
| **On-demand download** | Offer `whisper-large-v3` (~1.6 GB) as optional "High Accuracy" download from Pablo CDN |
| **Model cache** | Store in `~/Library/Application Support/PabloCompanion/Models/` |
| **Updates** | Check for model updates on app launch (background, non-blocking) |

Diarization models (Silero VAD ~2 MB, ECAPA-TDNN ~20 MB) are small enough to always bundle.

---

## 8. HIPAA Considerations

### December 2025 HIPAA Encryption Update

As of the December 2025 HIPAA rule update, **all ePHI must be encrypted — no exceptions.** The previous "addressable" standard has been eliminated. This means encryption is now a hard requirement, not a recommendation. Our architecture already meets this, but it's worth noting for compliance documentation.

### On-Device (Local Mode)

| Concern | Mitigation |
|---------|-----------|
| Audio files at rest | AES-256-GCM encryption (already implemented in `RecordingEncryptor`); unique rotating keys per file |
| Transcript at rest (before upload) | Encrypt with same device key; AES-256-GCM |
| Temp files during ASR | Process in memory where possible; if temp files needed, encrypt with AES-256-GCM, securely delete (overwrite + unlink) immediately after use |
| Model files | Not PHI (pretrained on public datasets — LibriSpeech, VoxCeleb — no patient data) |
| Voiceprint embeddings (couples only) | Biometric identifier — encrypt, store in encrypted SQLite keyed by patient ID |
| Processing in RAM | Standard — no special mitigation needed (RAM is volatile) |
| Audio never leaves device | Strongest privacy posture — document for customers |
| Key management | Store encryption keys in platform keychain (macOS Keychain, Windows Credential Manager); consider envelope encryption (DEK encrypted by KEK in keychain) |
| Secure temp directory | Use app sandbox container on macOS; `%LOCALAPPDATA%\Temp` within protected user profile on Windows |

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
- [ ] 1:1 pipeline: transcribe mic → THERAPIST, transcribe system → CLIENT, merge by timestamp (no diarization)
- [ ] Canonical JSON output
- [ ] Google Meet format export
- [ ] New API endpoint: `POST /api/sessions/{id}/transcript`
- [ ] Backend stores transcript
- [ ] Settings UI: quality preset, auto-transcribe toggle
- [ ] Model bundling (ship `whisper-small` in app)

### Phase 2: Couples Counseling + Speaker Enrollment

**Goal:** Support 3 speakers with enrollment-based labeling for returning couples

- [ ] Speaker embedding extraction (ECAPA-TDNN via ONNX) in Rust core
- [ ] 2-speaker diarization on system audio channel (VAD → embeddings → AHC clustering)
- [ ] "Name the speakers" UI — first couples session: play clips, therapist assigns names
- [ ] Cosine similarity matching for returning clients across sessions
- [ ] Client voiceprint encrypted storage (SQLite local + backend sync, keyed by patient ID)
- [ ] Session type setting (1:1 vs couples)
- [ ] Enrollment consent dialog (biometric data collection — required before storing any voiceprint)

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
| **Recording: 1 file vs 2 files** | Multi-channel WAV vs separate mic/system files | **✅ 2 separate files** — decided | Simpler tooling, standard mono/stereo WAV formats |
| **Recording library** | Keep AudioCaptureKit vs replace | **✅ Extend AudioCaptureKit** — decided. See `audiocapturekit-separate-streams-design.md` | First-party library, API extension is clean |
| **Whisper integration** | `whisper-rs` (Rust) vs Swift C FFI to `whisper.cpp` | `whisper-rs` in core/ — keeps business logic in Rust | Affects Rust core timeline |
| **Diarization runtime** | ONNX via `ort` (Rust) vs Python subprocess vs Swift ONNX | ONNX via `ort` in Rust core | Best for cross-platform |
| **Embedding model** | ECAPA-TDNN (SpeechBrain) vs pyannote's segmentation model | ECAPA-TDNN (well-understood, ONNX-exportable, 192-dim) | Affects enrollment storage |
| **Cloud diarization** | `pyannote.audio` vs NVIDIA NeMo | `pyannote.audio` (better community, overlap support) | Backend only |
| **Voiceprint storage location** | Keychain vs encrypted SQLite vs backend | **✅ Decided:** encrypted SQLite (local) + backend for couples clients only. No therapist voiceprint. | Mic channel = therapist; only couples clients need embeddings |
| **Model distribution** | Bundle in app vs download on first use | Bundle small; download medium/large on demand | Affects app size (~200 MB for small) |

---

## 12. Open Questions

~~1. Does AudioCaptureKit support separate streams?~~ **Resolved.** AudioCaptureKit is a first-party Pablo framework. We will add a `streamMode: .separateFiles` API. See `docs/audiocapturekit-separate-streams-design.md`.

~~2. What's the exact Google Meet transcript format?~~ **Resolved.** Confirmed from `meeting-transcription` repo synthetic session data. Exact format documented in §6 above.

~~3. Org-level settings for cloud mode~~ **Resolved.** The Pablo backend uses system-level settings (not org/tenant settings). Cloud mode toggle will be a system setting, not a per-user or per-org setting.

4. **pyannote model licensing** — `community-1` is CC-BY-4.0 and not gated (good news). For client-side ONNX exports of individual components (segmentation model, embedding model), verify redistribution rights under CC-BY-4.0 — attribution required but should be straightforward.

5. **Enrollment consent** — recording a voiceprint is biometric data collection. Do we need explicit consent UI beyond HIPAA? (State laws like BIPA in Illinois require it.) **Recommended: yes, always show an explicit consent dialog before enrollment** regardless of state — it's good UX, protects you legally in all states, and takes ~1 day to implement.

6. **Whisper model updates** — how do we ship updated/improved models to existing installs? **Recommendation:** version-check on app launch against a JSON manifest at a Pablo CDN URL. Download in background, swap on next transcription. User sees a non-disruptive "Model updated" notification. This is standard for AI-powered desktop apps and can be implemented in Phase 4.

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

---

## 14. Key References

| Topic | Source |
|-------|--------|
| whisper.cpp | github.com/ggml-org/whisper.cpp |
| whisper-rs (Rust bindings, v0.15.1) | crates.io/crates/whisper-rs |
| whisper-large-v3-turbo | huggingface.co/openai/whisper-large-v3-turbo |
| pyannote.audio community-1 (CC-BY-4.0) | huggingface.co/pyannote/speaker-diarization-community-1 |
| SpeechBrain ECAPA-TDNN | huggingface.co/speechbrain/spkrec-ecapa-voxceleb |
| WeSpeaker ECAPA-TDNN (ONNX available) | huggingface.co/Wespeaker/wespeaker-ecapa-tdnn512-LM |
| ort crate (ONNX Runtime for Rust) | crates.io/crates/ort |
| Cosine vs PLDA for embeddings | Wang et al., Interspeech 2022 |
| HIPAA encryption update (Dec 2025) | hipaajournal.com/hipaa-encryption-requirements |
| Silero VAD | github.com/snakers4/silero-vad |
| faster-whisper | github.com/SYSTRAN/faster-whisper |
| macOS ScreenCaptureKit | developer.apple.com/documentation/screencapturekit |
| WASAPI loopback recording | learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording |
