# Recording Resilience — Design Document

_Created: 2026-03-12_
_Status: DRAFT — awaiting review_

---

## 1. Problem Statement

On 2026-03-11, a real therapy session was lost because the app silently failed to capture audio after interruptions. The therapist had three recording sessions spanning ~45 minutes, but only ~7.75 minutes of audio was actually captured. The remaining two sessions wrote **0 bytes of mic audio** — yet nothing in the UI indicated a problem.

### What Happened (Timeline Reconstruction)

| Time | Recording UUID | Mic PCM | System PCM | Notes |
|------|---------------|---------|------------|-------|
| 10:01:51 | BD3C59BE | 350 KB (~1.8s) | 700 KB | Short — false start / test |
| 10:01:56 | 86D8B59E | 0 bytes | 0 bytes | Empty — immediate crash |
| **10:07:57** | **F097F30F** | **44.5 MB (~7.75 min)** | **89 MB** | **Main session recording** |
| 10:17:22 | 5C63DC7C | 0 bytes | 192 KB (~0.5s) | Session ran 34 min, captured nothing |
| 10:52:41 | 6803C6CB | 0 bytes | 192 KB (~0.5s) | Session ran 9.5 min, captured nothing |

**Root cause**: AudioCaptureKit session produced empty mic PCM sidecar files after restart following interruptions. No error was surfaced — `CaptureState` reported `.capturing` normally while writing zero bytes.

### Contributing Factors

1. **No data flow monitoring** — nothing checks that bytes are actually being written
2. **No crash recovery** — app crash leaves session stuck "In Progress" on backend indefinitely
3. **In-memory only state** — `LocalRecording` metadata and `sessionRecordingMap` lost on crash
4. **Dismissible error alerts** — errors shown as `.alert()` modifiers that auto-dismiss
5. **No manual session control** — therapist can't end a stale "In Progress" session
6. **No pause/resume in main UI** — controls exist in `RecordingService` but aren't exposed

---

## 2. Audio Data Flow Watchdog

**Goal**: Detect within 60 seconds when recording appears active but no audio data is flowing.

### Design

```
RecordingService                    RecordingViewModel              DayView
     │                                     │                          │
     │ startRecording()                    │                          │
     ├─── start watchdog timer (60s)       │                          │
     │                                     │                          │
     │ [every 60s]                         │                          │
     │ stat(output file)                   │                          │
     │ stat(mic PCM sidecar)               │                          │
     │                                     │                          │
     │ if mic PCM size unchanged:          │                          │
     │   onRecordingStalled?() ──────────► │                          │
     │                                     │ recordingStalled = true   │
     │                                     │ ─────────────────────────►│
     │                                     │                          │ show stall warning banner
     │                                     │                          │
     │ if size increases again:            │                          │
     │   onRecordingResumed?() ──────────► │                          │
     │                                     │ recordingStalled = false  │
     │                                     │ ─────────────────────────►│
     │                                     │                          │ clear warning
```

### Watchdog Implementation

- New callback: `var onRecordingStalled: (() -> Void)?` on `RecordingService`
- New callback: `var onRecordingResumed: (() -> Void)?` on `RecordingService`
- Timer fires every 60 seconds during active recording
- Checks **mic PCM sidecar file** specifically (the file that matters for transcription)
- Stores previous file size; compares on each tick
- First check happens at 60s mark (gives capture time to initialize)
- Timer cancelled on `stopRecording()` or `pauseRecording()`; restarted on `resumeRecording()`

### Stall Warning Banner

- Persistent amber banner below the recording banner in DayView
- Text: "Audio capture may have stalled — no new data in the last 60 seconds"
- **"Retry Capture"** button: stops current capture, starts new recording file (same session)
- **"Dismiss"** button: hides the banner but leaves an amber indicator dot on the recording banner
- Clicking the dot re-shows the full warning

### Retry Capture Behavior

1. Stop current `CompositeCaptureSession` — partial recording preserved on disk
2. Start new `CompositeCaptureSession` with same config — new recording file
3. Update `sessionRecordingMap` to point to the **new** recording (the one with audio)
4. Both files kept on disk for potential manual recovery
5. Reset watchdog timer for the new session

### Files to Modify

| File | Change |
|------|--------|
| `Services/RecordingService.swift` | Add watchdog timer, `onRecordingStalled` / `onRecordingResumed` callbacks |
| `ViewModels/RecordingViewModel.swift` | Add `recordingStalled` state, wire callbacks, implement retry capture |
| `Views/DayView.swift` | Add stall warning banner, amber indicator dot |
| `Views/ContentView.swift` | Wire new callbacks and state |

---

## 3. Recording State Persistence

**Goal**: Survive app crashes — recordings and session mappings persist across restarts.

### Design

A `RecordingManifest.json` file in the recordings directory stores metadata for all local recordings and their session associations.

```json
{
  "version": 1,
  "recordings": [
    {
      "id": "F097F30F-8012-4BA0-91AC-C7854D45C4FA",
      "fileURL": "recording_F097F30F-8012-4BA0-91AC-C7854D45C4FA.enc.wav",
      "micPCMFile": "recording_F097F30F-..._mic.pcm",
      "systemPCMFile": "recording_F097F30F-..._system.pcm",
      "duration": 465.5,
      "createdAt": "2026-03-11T10:07:57Z",
      "isEncrypted": true,
      "checksum": "abc123...",
      "channelLayout": "separatedStereo",
      "isUploaded": false,
      "sessionId": "session-uuid-here"
    }
  ]
}
```

### Lifecycle

1. **On recording completion**: append entry to manifest, write to disk
2. **On session mapping**: update entry's `sessionId`, write to disk
3. **On app launch**: load manifest, rebuild `recordings` array and `sessionRecordingMap`
4. **On upload completion**: update `isUploaded`, write to disk
5. **Orphan detection**: entries without a `sessionId` are flagged for review

### Implementation

- New `RecordingManifestStore` class (Codable, reads/writes JSON)
- Stored in `~/Documents/MacOSSample-Recordings/RecordingManifest.json`
- File-relative paths in the manifest (portable if recordings dir moves)
- Write operations are atomic (write to temp file, rename)

### Files to Modify

| File | Change |
|------|--------|
| New: `Services/RecordingManifestStore.swift` | Codable manifest store |
| `ViewModels/RecordingViewModel.swift` | Persist on recording completion, load on init |
| `Models/LocalRecording.swift` | Add `Codable` conformance |

---

## 4. Crash Recovery & Stale Session Handling

**Goal**: Detect and recover from crashed sessions on app launch. Give therapists manual control over stale sessions.

### Auto-Detection on Launch

1. Persist `activeSessionId` to `@AppStorage("activeSessionId")` when recording starts
2. Clear it when recording stops normally
3. On launch: if `activeSessionId` is set but no recording is active → crash happened
4. Show recovery dialog:
   - "Pablo was interrupted during your last session."
   - **"End Session"** → `endSession()` on backend → `recordingComplete`
   - **"Cancel Session"** → marks as cancelled on backend
   - **"Dismiss"** → leaves as-is (therapist can handle later)

### Manual "End Session" Button

- Sessions with `status == .inProgress` and no active recording show an **"End Session"** button in `SessionRowView`
- One tap → calls `endSession()` on backend → refreshes session list
- Replaces the "Start Session" button area for stale sessions

### Files to Modify

| File | Change |
|------|--------|
| `Views/ContentView.swift` | Persist `activeSessionId` to `@AppStorage`, launch recovery check |
| `ViewModels/SessionViewModel.swift` | Add `endStaleSession()` method |
| `Views/SessionRowView.swift` | Add "End Session" button for stale in-progress sessions |
| `Views/DayView.swift` | Pass through `isRecordingActive` for stale session detection |

---

## 5. Error Surfacing Improvements

**Goal**: Recording errors are unmissable — no silent failures.

### Persistent Error Banner

- New banner in DayView (below recording banner), styled with terracotta/red background
- Stays visible until explicitly dismissed or the error condition is resolved
- Shows: error description + timestamp + action button if applicable

### macOS System Notification

- When a recording error occurs and the app is **not** the frontmost window
- Uses `UNUserNotificationCenter` for a native macOS notification
- Title: "Pablo Recording Issue"
- Body: brief error description
- Click → brings app to front

### Error State on Session Rows

- Sessions where recording failed show an error indicator (red dot or icon) in `SessionRowView`
- Hovering shows the error message in a tooltip

### Files to Modify

| File | Change |
|------|--------|
| `Views/DayView.swift` | Add persistent error banner |
| `Views/SessionRowView.swift` | Add error indicator |
| `ViewModels/RecordingViewModel.swift` | Track error state per session |
| New: `Services/NotificationService.swift` | macOS notification helper |

---

## 6. Stale Transcription State Cleanup

**Goal**: "Awaiting model" badges don't persist after model is available.

### Current Bug

1. Auto-transcribe runs → model not available → state set to `.awaitingModel`
2. Model downloads → `processAwaitingModelRecordings` runs
3. But if the recording has 0 bytes mic PCM, transcription fails
4. State stays `.awaitingModel` — badge persists on session row

### Fix

In `transcriptionStateForSession` (ContentView line 143):
```swift
private func transcriptionStateForSession(_ sessionId: String) -> TranscriptionState? {
    guard let recordingId = recordingVM.sessionRecordingMap[sessionId] else {
        return nil
    }
    let state = transcriptionVM.states[recordingId]
    // Don't show stale "awaiting model" if a model is now available
    if case .awaitingModel = state, transcriptionVM.awaitingModelCount == 0 {
        return nil  // Model is available — re-trigger transcription or show "Transcribe"
    }
    return state
}
```

Also: in `processAwaitingModelRecordings`, validate that the mic PCM file has content before retrying. If it doesn't, transition to `.failed(message: "No mic audio captured")` instead of leaving as `.awaitingModel`.

### Files to Modify

| File | Change |
|------|--------|
| `Views/ContentView.swift` | Fix `transcriptionStateForSession` |
| `ViewModels/TranscriptionViewModel.swift` | Validate mic PCM before retry, clean up stale states |

---

## 7. Pause/Resume Controls in Recording Banner

**Goal**: Therapists can pause and resume recording during a session.

### Current State

- `RecordingService.pauseRecording()` and `resumeRecording()` exist (lines 112-136)
- `RecordingViewModel` wraps these
- DayView recording banner shows "Paused" text when `recordingState == .paused`
- **Missing**: no Pause/Resume button in the banner — only "Stop" exists

### Design

```
Recording state:  ⬤ Recording  3:42   [⏸ Pause] [■ Stop]
Paused state:     ⬤ Paused     3:42   [▶ Resume] [■ Stop]
```

- Pause button: `systemImage: "pause.fill"`, honey color
- Resume button: `systemImage: "play.fill"`, sage green
- Paused state: banner background changes from sage green tint to amber tint
- Watchdog timer pauses when recording pauses, resumes when recording resumes

### Files to Modify

| File | Change |
|------|--------|
| `Views/DayView.swift` | Add Pause/Resume button to recording banner |
| `Views/ContentView.swift` | Wire `onPauseRecording` / `onResumeRecording` callbacks |

---

## 8. E2E Test Automation

### MCP Servers

Two MCP servers enable automated build/test/UI verification:

1. **XcodeBuildMCP** (https://github.com/getsentry/XcodeBuildMCP)
   - Install: `brew tap getsentry/xcodebuildmcp && brew install xcodebuildmcp`
   - Provides: build, test, project management, error reading via MCP

2. **macOS UI Automation MCP** (https://github.com/mb-dev/macos-ui-automation-mcp)
   - Install: `git clone` + `uv sync`
   - Provides: UI element inspection via Accessibility APIs, click/type simulation
   - Requires: Accessibility permission for the host terminal app

### XCUITest Suite

| Test | Scenario | Verifies |
|------|----------|----------|
| `testWatchdogStalledRecording` | Start recording, mock stalled file write → verify stall banner | Watchdog |
| `testRetryCaptureClearsStall` | Trigger stall → tap "Retry Capture" → verify recording resumes | Retry |
| `testRecordingPersistsAcrossRestart` | Record → stop → relaunch → verify recording in list | Persistence |
| `testCrashRecoveryDialog` | Persist activeSessionId, launch with stale session → verify dialog | Crash recovery |
| `testManualEndSession` | Stale in-progress session → verify "End Session" button | Manual end |
| `testPauseResumeControls` | Start recording → verify Pause → tap → verify Resume | Pause/Resume |
| `testErrorBannerPersistence` | Trigger recording error → verify banner stays visible | Error surfacing |

---

## 9. Implementation Priority

| Priority | Tasks | Rationale |
|----------|-------|-----------|
| **P1 — Ship first** | Watchdog (T1), Persistence (T2), Crash recovery (T3), Error banner (T4), Manual end session (T6) | Prevents data loss — the core issue |
| **P2 — Ship second** | Stale transcription cleanup (T5), Pause/Resume (T7), System notifications (T9), MCP + tests (T10) | Improves UX, prevents confusion |
| **P3 — Nice to have** | Audio level indicators (T8) | Confidence-building, not strictly required |
