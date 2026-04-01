# Practice Mode — Windows Client Implementation Guide

_For: Claude Code / Windows developer_
_Reference commit: `feat/practice-mode-client` branch on `pablo-companion`_

---

## What This Document Is

This is a self-contained guide for implementing the Windows (WinUI 3 / C#) practice mode client. It references the macOS implementation for parity and the backend API contract for protocol details.

---

## 1. What Practice Mode Does

A therapist conducts a simulated therapy session with **Pablo Bear** (AI patient). The therapist speaks via microphone, audio streams to the backend over WebSocket, the backend connects to Gemini Live API, and returns Pablo's voice response. Both audio channels are captured for transcription → SOAP note generation.

**The client is a thin audio pipe.** All conversation intelligence (VAD, turn-taking, AI responses) is server-side.

---

## 2. Reference Documents

| Document | Location | Purpose |
|----------|----------|---------|
| **Backend API contract** | `therapy-assistant-platform/docs/practice-mode-api.md` | Full REST + WebSocket protocol spec |
| **Design doc** | `pablo-companion/docs/practice-mode-design.md` | Architecture, HIPAA analysis, phased delivery |
| **macOS implementation** | `pablo-companion/mac/PabloCompanion/` (see file list below) | Reference for parity |

---

## 3. macOS Implementation Reference

The macOS client is fully implemented. Use it as the reference for behavior and UI.

### File Map (Swift → C# equivalents needed)

| macOS File | Purpose | Windows Equivalent |
|------------|---------|-------------------|
| `Models/PracticeTopic.swift` | Topic data model (Codable) | `Models/PracticeTopic.cs` |
| `Models/PracticeSession.swift` | Session response DTOs (Codable) | `Models/PracticeSession.cs` |
| `Services/PracticeAPIClient.swift` | REST client for topics + sessions | `Services/PracticeApiClient.cs` |
| `Services/PracticeWebSocketClient.swift` | WebSocket client (hybrid text/binary protocol) | `Services/PracticeWebSocketClient.cs` |
| `Services/PracticeAudioPlayer.swift` | Plays Pablo's 24kHz PCM via system audio | `Services/PracticeAudioPlayer.cs` |
| `Services/PracticeMicCapture.swift` | Captures mic, downsamples to 16kHz PCM | `Services/PracticeMicCapture.cs` |
| `ViewModels/PracticeViewModel.swift` | Orchestrates session lifecycle | `ViewModels/PracticeViewModel.cs` |
| `Views/PracticeTopicSheet.swift` | Topic picker UI | `Views/PracticeTopicSheet.xaml` |
| `Views/PracticeSessionView.swift` | Main session UI (Pablo Bear, waveform, timer) | `Views/PracticeSessionView.xaml` |
| `Views/PracticeEndedView.swift` | Session ended confirmation | `Views/PracticeEndedView.xaml` |
| `Views/ContentView+Practice.swift` | Sheet presentation logic | Integrate into `MainWindow.xaml` |

---

## 4. API Contract Summary

Full spec is in `therapy-assistant-platform/docs/practice-mode-api.md`. Key points:

### REST Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| `GET /api/practice/topics` | List practice topics |
| `POST /api/practice/sessions` | Create session (returns `session_id` + `ws_url`) |
| `GET /api/practice/sessions` | List user's practice sessions |
| `GET /api/practice/sessions/{id}` | Get session detail + SOAP note |
| `POST /api/practice/sessions/{id}/end` | End session via REST (fallback) |

Auth: Firebase JWT in `Authorization: Bearer <token>` header.

### WebSocket Protocol

**Endpoint:** `wss://api.pablo.health/api/practice/ws?token=<firebase_jwt>`

**Frame types:**
- **Text frames** — JSON control messages
- **Binary frames** — PCM audio with 4-byte header

**Connection flow:**
```
Connect with token → auth_result → session_start {session_id}
→ session_started {audio_config} → audio streaming → session_end → session_ended
```

**Binary frame format:**

```
Byte    Field          Type              Description
[0]     direction      uint8             0x01 (client→server) or 0x02 (server→client)
[1]     flags          uint8             Bit 0: is_final (last chunk for turn)
[2-3]   sequence       uint16 BE         Wraps at 65535
[4..]   pcm_data       bytes             PCM 16-bit signed LE, mono
```

- Client sends: 16kHz, 20ms chunks (640 bytes PCM + 4-byte header = 644 bytes)
- Server sends: 24kHz PCM + 4-byte header

**Control messages (JSON text frames):**

Client → Server: `session_start`, `session_end`, `session_resume`, `audio_pause`, `audio_resume`, `ping`

Server → Client: `auth_result`, `session_started`, `session_ended`, `status` (listening/processing/speaking), `pong`, `error`, `fatal_error`

**Heartbeat:** Client sends `ping` every 15 seconds. Server responds with `pong`.

**Reconnection:** Send `session_resume` with `session_id` + `last_sequence`. 30-second reconnection window.

---

## 5. Windows-Specific Implementation Notes

### Audio Capture (Mic → WebSocket)

Use **WASAPI** (Windows Audio Session API) for mic capture:

```csharp
// Pseudo-code for WASAPI mic capture
var capture = new WasapiCapture(selectedMic);
capture.WaveFormat = new WaveFormat(48000, 16, 1); // Hardware rate
// Downsample 48kHz → 16kHz using MediaFoundation resampler or NAudio
// Chunk into 20ms frames (320 samples = 640 bytes at 16kHz)
// Send via WebSocket with 4-byte header
```

Libraries: **NAudio** (NuGet) provides WASAPI wrappers and resampling.

### Audio Playback (WebSocket → System Speakers)

Use **WASAPI shared mode** for playback:

```csharp
// Pseudo-code for audio playback
var player = new WasapiOut(AudioClientShareMode.Shared, latency: 50);
// Feed 24kHz PCM chunks from WebSocket into a BufferedWaveProvider
// Playing through shared mode = captured by any system audio recorder
```

### WebSocket Client

Use `System.Net.WebSockets.ClientWebSocket`:

```csharp
var ws = new ClientWebSocket();
await ws.ConnectAsync(new Uri(wsUrl), cancellationToken);

// Send text (JSON control messages)
await ws.SendAsync(jsonBytes, WebSocketMessageType.Text, true, ct);

// Send binary (audio frames with header)
await ws.SendAsync(audioFrame, WebSocketMessageType.Binary, true, ct);

// Receive loop
while (ws.State == WebSocketState.Open) {
    var result = await ws.ReceiveAsync(buffer, ct);
    if (result.MessageType == WebSocketMessageType.Text) { /* JSON */ }
    else if (result.MessageType == WebSocketMessageType.Binary) { /* audio */ }
}
```

### MVVM Pattern

Use WinUI 3's `CommunityToolkit.Mvvm`:
- `ObservableObject` base class (equivalent to Swift's `@Observable`)
- `ObservableProperty` attribute (equivalent to `var` in `@Observable`)
- `RelayCommand` for button bindings

### Auth

Firebase JWT from the Windows auth flow. Pass as query parameter for WebSocket, as Bearer header for REST.

---

## 6. UI Parity Checklist

The Windows UI should match the macOS behavior:

### Topic Picker
- [ ] List topics with name, description, estimated duration
- [ ] Single-select, highlight selected topic
- [ ] "Start Session" button (disabled until topic selected)
- [ ] "Cancel" button

### Practice Session View
- [ ] Pablo Bear illustration (use `pawprint.fill` or custom asset)
- [ ] Glow/highlight when Pablo is speaking
- [ ] Waveform bars: one for Pablo (honey color), one for therapist (sage color)
- [ ] Duration timer (MM:SS, monospaced)
- [ ] Topic name displayed
- [ ] Status badge: "Listening" / "Thinking..." / "Speaking"
- [ ] Pause/Resume button
- [ ] End Session button (red/terracotta)
- [ ] Connecting state with progress indicator

### Session Ended View
- [ ] Checkmark icon
- [ ] "Practice Session Complete" heading
- [ ] Topic name + duration
- [ ] "Your SOAP note is being generated" message
- [ ] Done button

### Design System

| Element | Value |
|---------|-------|
| Primary CTA | Honey `#D4922E` |
| Background | Warm Cream `#FDF6EC` |
| Text primary | Deep Brown `#2C1810` |
| Active / recording | Sage Green `#7A9E7E` |
| Error / destructive | Terracotta Red `#C45B4A` |
| Body font | DM Sans |
| Display font | Fraunces |
| Corner radius | 8px |

### Accessibility
- All buttons must have accessible labels
- Decorative images must be hidden from screen readers
- Animations must respect "Reduce motion" system setting
- Don't use color alone to convey state (always pair with text/icon)

---

## 7. Integration with Existing Session Pipeline

After practice session ends:

1. Stop audio recording (both channels)
2. Upload audio via `POST /api/sessions/{session_id}/upload-audio` (existing endpoint, dual-channel multipart)
3. Backend transcribes → generates SOAP note → status moves to `pending_review`
4. Practice sessions appear in session history with "Practice" badge
5. Practice sessions use `source="practice"` — filtered from clinical views

---

## 8. Rate Limits

- 10 sessions/user/day
- 1 concurrent session/user
- 30 minutes max duration/session

Handle `429 Too Many Requests` (REST) and `4003` close code (WebSocket) gracefully.

---

## 9. Error Handling

| Scenario | Behavior |
|----------|----------|
| WebSocket disconnects | Show error, attempt reconnect with `session_resume` |
| Auth token expired | Refresh token, reconnect |
| Gemini timeout (recoverable) | Show toast, therapist speaks again |
| Gemini connection lost (fatal) | End session, show error |
| Idle timeout (10 min) | Server ends session automatically |
| Duration limit (30 min) | Server ends session, show "Session Complete" |

---

## 10. Testing

- Unit test WebSocket message parsing (JSON control messages, binary header parsing)
- Unit test audio frame construction (4-byte header + PCM)
- Integration test with backend WebSocket endpoint
- Manual test: verify system audio capture picks up playback
- Manual test: full session → SOAP note pipeline
