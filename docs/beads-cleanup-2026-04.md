# Beads backlog cleanup — 2026-04

Discovered during the codebase-quality review on branch `claude/review-codebase-quality-Id4iJ`.
109 issues were open; several are stale after the Rust → native (Swift + C#) refactor in commit `5f05c87`.
This doc lists the grooming actions to take once the team is ready.

## Close as superseded (Rust-era work — no longer applicable)

| ID | Title | Reason |
|----|-------|--------|
| `PABLO-D-105.1` | Rust core: Silero VAD + ECAPA-TDNN speaker embeddings (ONNX, lazy-load) | Rust core removed; if diarization is still wanted, file a fresh issue against the native stack |
| `PABLO-D-105.2` | Rust core: AHC clustering + smoothing for 2-speaker diarization | Same as above |
| `PABLO-D-105.3` | Rust core: cosine similarity client matching across sessions | Same as above |
| `PABLO-D-105.4` | Rust core: couples transcription pipeline | Same as above |
| `PABLO-D-xfz.2` | Rust → C# UniFFI bindings setup | UniFFI layer removed |
| `PABLO-D-113.1` | PreferencesViewModel — load/save via Rust API | No Rust API; re-file against backend REST if still needed |

Run:

```bash
for id in PABLO-D-105.1 PABLO-D-105.2 PABLO-D-105.3 PABLO-D-105.4 PABLO-D-xfz.2 PABLO-D-113.1; do
  bd close "$id" --reason="Superseded by Rust → native refactor (commit 5f05c87). Re-file against native stack if still desired."
done
```

## Verify and close if delivered (likely done, confirm before closing)

| ID | Title | Evidence suggesting done |
|----|-------|--------------------------|
| `PABLO-D-8fd` | Epic 1: Project Foundation | App builds, runs, releases — foundation is clearly in place |
| `PABLO-D-7i1` | Epic 2: AudioCaptureKit Integration | AudioCaptureKit is an active SPM dependency and used by `RecordingService` |

For each, spot-check the sub-tasks before closing the epic.

## Reconciliation with CLAUDE.md

CLAUDE.md previously claimed "Beads tasks: `PABLO-D-050` through `PABLO-D-057`" for onboarding — these IDs never existed. That claim has been updated in this PR to point at the real onboarding epic, `PABLO-D-112`. No beads action needed.

## Cross-platform parity item (not currently tracked)

`PABLO-D-106` ("Epic: Transcription Phase 3 — Cloud Mode") exists but is P3. Given that macOS has already removed local Whisper (commit `5b50326`), Windows is now the only platform doing local transcription — this creates behavioral divergence. Consider bumping `PABLO-D-106` to P1 and adding explicit sub-tasks for the Windows Whisper removal.
