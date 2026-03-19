# Windows Audio Recording — Feature Parity with macOS

## Context

The macOS app captures mic + system audio during therapy sessions via AudioCaptureKit (Swift Package). The Windows app has no recording capability. AudioCaptureKit already has a **Windows Rust implementation** (`audio-capture-core` + `audio-capture-windows` crates) with WASAPI mic capture, loopback system audio, stereo mixing, and AES-256-GCM encryption — but no C# bindings. This plan embeds those crates into `pablo-core` and exposes them via UniFFI so the WinUI 3 app can use them through the existing `PabloCoreMethods.*` pattern.

## Architecture

```
AudioCaptureKit repo (no changes)
├── windows/audio-capture-core/     ← platform-agnostic traits, models, mixer, encryption
└── windows/audio-capture-windows/  ← WASAPI mic + loopback (762 LOC)

pablo-core (changes here)
├── Cargo.toml                      ← add audio-capture-core + audio-capture-windows deps
├── src/audio_capture.rs            ← UniFFI-friendly wrapper module
└── uniffi/pablo_core.udl           ← new types + functions for audio capture

pablo-companion windows/ (changes here)
├── Generated/pablo_core.cs         ← regenerated with audio capture bindings
├── Services/RecordingService.cs    ← orchestrates capture via Rust FFI
├── ViewModels/RecordingViewModel.cs
└── Views/                          ← recording banner, settings audio section
```

## Phase 1: Rust Core — Embed Audio Capture in pablo-core

### UniFFI Design Challenges & Solutions

| Challenge | Solution |
|-----------|----------|
| `CompositeSession<M, S>` is generic | Create concrete type alias: `type WindowsCaptureSession = CompositeSession<WasapiMicCapture, WasapiLoopbackCapture>` |
| `CaptureDelegate` trait (callbacks) | Use UniFFI `[Trait, WithForeign]` callback interface — C# implements it, Rust calls it |
| `CaptureEncryptor` is `Box<dyn>` | Create concrete `AesGcmEncryptor` in pablo-core, construct on Rust side from key bytes |
| `CaptureConfiguration.encryptor` field | Build config in Rust from flat params (key bytes + bool), not from a trait object across FFI |
| Stateful session | Expose as UniFFI `[Object]` (opaque handle) with methods |

### Files to modify in `core/`

**`core/Cargo.toml`**
- Add under `[target.'cfg(target_os = "windows")'.dependencies]`:
  - `audio-capture-core = { path = "../path-or-git-ref" }` (or git dependency pointing to AudioCaptureKit repo)
  - `audio-capture-windows = { path = "../path-or-git-ref" }`
- Add `audio-capture` feature flag (default-enabled on Windows, disabled on macOS)

**`core/src/audio_capture.rs`** (new, ~250 lines) — UniFFI-friendly wrapper
- `AudioCaptureSession` struct wrapping `CompositeSession<WasapiMicCapture, WasapiLoopbackCapture>`
- Flattened constructor: `fn new(output_dir: String, mic_device_id: Option<String>, ...) -> Self`
- Methods mapped 1:1 from `CaptureSession` trait:
  - `fn configure(config: AudioCaptureConfig) -> Result<(), PabloError>`
  - `fn start_capture() -> Result<(), PabloError>`
  - `fn pause_capture() -> Result<(), PabloError>`
  - `fn resume_capture() -> Result<(), PabloError>`
  - `fn stop_capture() -> Result<CaptureRecordingResult, PabloError>`
  - `fn current_levels() -> CaptureAudioLevels`
  - `fn state() -> CaptureSessionState` (simplified enum without associated data)
  - `fn available_audio_sources() -> Result<Vec<CaptureAudioSource>, PabloError>`
- `fn list_audio_devices() -> Result<Vec<CaptureAudioSource>, PabloError>` (standalone, no session needed)
- `fn check_microphone_permission() -> Result<bool, PabloError>`
- Re-export AudioCaptureKit models as UniFFI-friendly types (no generics, no trait objects, simple value types)

**`core/src/lib.rs`**
- Add `#[cfg(target_os = "windows")] mod audio_capture;`
- Re-export the public types

**`core/uniffi/pablo_core.udl`** — add audio capture types:

```
// ── Audio Capture (Windows) ──────────────────────────────────

[Object]
interface AudioCaptureSession {
    constructor(string output_dir);
    [Throws=PabloError] void configure(AudioCaptureConfig config);
    [Throws=PabloError] void start_capture();
    [Throws=PabloError] void pause_capture();
    [Throws=PabloError] void resume_capture();
    [Throws=PabloError] CaptureRecordingResult stop_capture();
    CaptureAudioLevels current_levels();
    string capture_state();  // "idle" | "capturing" | "paused" | "stopping"
    [Throws=PabloError] sequence<CaptureAudioSource> available_audio_sources();
};

dictionary AudioCaptureConfig {
    string? mic_device_id;
    boolean enable_mic;
    boolean enable_system;
    string mixing_strategy;        // "separated" | "blended"
    boolean export_raw_pcm;
    boolean encryption_enabled;
    sequence<u8>? encryption_key;  // 32 bytes AES-256, or null
};

dictionary CaptureAudioLevels {
    float mic_level;
    float system_level;
    float peak_mic_level;
    float peak_system_level;
};

dictionary CaptureAudioSource {
    string id;
    string name;
    string source_type;      // "mic" | "system"
    boolean is_default;
    string? transport_type;  // "built_in" | "bluetooth" | "usb" | "virtual"
};

dictionary CaptureRecordingResult {
    string file_path;
    double duration_secs;
    string checksum;
    boolean is_encrypted;
    string channel_layout;         // "separated_stereo" | "blended" | "mono"
    sequence<string> pcm_file_paths;
};
```

**`PabloError`** — add variant:
```
AudioCapture(string message);
```

### Regenerate C# bindings

After UDL changes, run `cargo run --bin uniffi-bindgen generate ...` to regenerate `windows/PabloCompanion/Generated/pablo_core.cs`. This gives the C# app `AudioCaptureSession`, `AudioCaptureConfig`, etc. as native C# classes.

---

## Phase 2: Windows C# — Recording Service Layer

### New files

**`windows/PabloCompanion/Models/LocalRecording.cs`**
- Record: `Guid Id`, `string FilePath`, `double Duration`, `DateTime CreatedAt`, `bool IsEncrypted`, `string Checksum`, `string ChannelLayout`, `string? MicPcmFilePath`, `string? SystemPcmFilePath`, `bool IsUploaded`

**`windows/PabloCompanion/Models/RecordingState.cs`**
- `RecordingUIState` enum: `Idle`, `Recording`, `Paused`

**`windows/PabloCompanion/Services/RecordingService.cs`** (~200 lines)
- Wraps `AudioCaptureSession` (UniFFI-generated C# class)
- Manages lifecycle: create session → configure → start → poll levels → stop → return LocalRecording
- Builds `AudioCaptureConfig` from user settings (mic ID, encryption key from CredentialManager, etc.)
- Level polling: `System.Threading.Timer` at 66ms, reads `session.CurrentLevels()`, stores in `Interlocked` slot
- Stall detection: monitors duration progress every 60s
- Device enumeration: delegates to `session.AvailableAudioSources()`
- SHA-256 checksum comes back from Rust in `CaptureRecordingResult`

**`windows/PabloCompanion/Services/SessionRecordingStore.cs`** (~80 lines)
- Persists `Dictionary<string, RecordingEntry>` as JSON to `%LOCALAPPDATA%\PabloCompanion\SessionRecordings.json`
- Same structure as macOS `SessionRecordingStore.swift`

**`windows/PabloCompanion/Services/RecordingDirectoryScanner.cs`** (~60 lines)
- Scans `%LOCALAPPDATA%\PabloCompanion\Recordings/` for orphaned WAV/PCM files
- Groups by UUID, excludes linked recordings

### Modified files

**`windows/PabloCompanion/Services/CredentialManager.cs`**
- Add `DeviceEncryptionKey` property (get/set Base64-encoded 32-byte key)
- Add `GetOrCreateDeviceEncryptionKey()` — generates random key if none exists
- Add `"deviceEncryptionKey"` to `TokenKeys` array for sign-out cleanup

---

## Phase 3: Windows C# — ViewModel

**`windows/PabloCompanion/ViewModels/RecordingViewModel.cs`** (~250 lines)
- `ObservableObject` (CommunityToolkit.Mvvm)
- Observable properties:
  - `RecordingUIState RecordingState`, `double Duration`
  - `float MicLevel`, `float SystemLevel`, `float PeakMicLevel`, `float PeakSystemLevel`
  - `CaptureAudioSource[] AvailableMics`, `string? SelectedMicId`
  - `bool EncryptionEnabled`, `bool SystemAudioActive`
  - `string? ErrorMessage`, `bool RecordingStalled`
  - `string? ActiveSessionId`
  - `LocalRecording[] Recordings`
- RelayCommands: `StartRecordingAsync`, `StopRecordingAsync`, `PauseRecording`, `ResumeRecording`, `LoadAudioDevicesAsync`
- Level polling: `DispatcherTimer` at 66ms reads from `RecordingService`
- Session mapping via `SessionRecordingStore`
- `ClearAllData()` for sign-out

**`windows/PabloCompanion/App.xaml.cs`** — register in DI:
```csharp
services.AddSingleton<Services.RecordingService>();
services.AddSingleton<Services.SessionRecordingStore>();
services.AddSingleton<ViewModels.RecordingViewModel>();
```

---

## Phase 4: Windows C# — UI Changes

**New: `windows/PabloCompanion/Views/RecordingBanner.xaml/.cs`**
- UserControl: green dot + "Recording"/"Paused" + duration (monospaced) + system audio status dot + Stop button
- Stall warning row
- Matches macOS `DayView.recordingBanner` visual pattern

**Modify: `windows/PabloCompanion/Views/DayPage.xaml/.cs`**
- Insert `RecordingBanner` between error banner and session list (new Grid row)
- Get `RecordingViewModel` from DI, bind banner visibility to recording state

**Modify: `windows/PabloCompanion/Views/SessionRowControl.xaml/.cs`**
- Add green recording dot when session ID matches active recording

**Modify: `windows/PabloCompanion/Views/SettingsPage.xaml/.cs`**
- Add "Audio" section: mic dropdown, encryption toggle, mic permission status
- Test tone button (generates 3s 440Hz/880Hz stereo WAV — same as macOS)

**Modify: `windows/PabloCompanion/ViewModels/SessionViewModel.cs`**
- Wire `StartSessionAsync` → `RecordingViewModel.StartRecordingAsync`
- Wire `EndSessionAsync` → `RecordingViewModel.StopRecordingAsync`

**Modify: `windows/PabloCompanion/ViewModels/AuthViewModel.cs`**
- `SignOut()` calls `RecordingViewModel.ClearAllData()`

---

## Phase 5: Tests

| File | Tests |
|------|-------|
| `Tests/Services/SessionRecordingStoreTests.cs` | Save/load round-trip, merge, missing file |
| `Tests/Services/RecordingDirectoryScannerTests.cs` | File grouping, UUID extraction, exclusion |
| `Tests/ViewModels/RecordingViewModelTests.cs` | State transitions (mock RecordingService), level flow, session mapping |

Note: `AudioCaptureSession` (Rust FFI) can't be easily mocked in unit tests. `RecordingService` wraps it, and `RecordingViewModel` tests mock `RecordingService`. Integration testing requires Windows hardware.

---

## Implementation Order

```
Phase 1: core/ changes           — Cargo deps, audio_capture.rs wrapper, UDL, regenerate C# bindings
Phase 2: C# services             — RecordingService, SessionRecordingStore, CredentialManager extension
Phase 3: RecordingViewModel      — Business logic + DI registration
Phase 4: UI                      — RecordingBanner, DayPage, SettingsPage, session wiring
Phase 5: Tests                   — Written alongside each phase
```

Phases 1→2→3→4 are sequential (each depends on prior). Tests are parallel with each phase.

---

## Key Design Decisions

1. **Embed in pablo-core** (not separate UniFFI crate) — one DLL, one set of C# bindings, established pattern
2. **`#[cfg(target_os = "windows")]`** on audio capture module — macOS uses AudioCaptureKit Swift package directly, never goes through Rust for audio capture
3. **Flat UniFFI types** — no generics, no trait objects across boundary. `AudioCaptureConfig` uses `sequence<u8>?` for encryption key, `string` for enum-like values where UniFFI enums are awkward
4. **`AudioCaptureSession` as `[Object]`** — stateful handle with methods, not free functions. Matches how the Rust `CompositeSession` works
5. **System audio always available on Windows** — WASAPI loopback needs no special permission (unlike macOS Screen Recording). Mic requires Windows privacy consent
6. **Level polling in C#, not Rust callbacks** — C# `DispatcherTimer` polls `session.CurrentLevels()` at 15fps. Simpler than UniFFI callback interfaces for high-frequency data. Matches macOS `CaptureDelegateAdapter` polling pattern

---

## Verification

1. **Rust**: `cargo build --target x86_64-pc-windows-msvc` passes with audio capture module
2. **Bindings**: Regenerated `pablo_core.cs` contains `AudioCaptureSession` class
3. **C# build**: `dotnet build` on `windows/PabloCompanion.sln` passes
4. **Unit tests**: `dotnet test` — RecordingViewModel state machine, store persistence
5. **Manual on Windows**: Start session → recording banner appears with "System Audio" indicator → play audio → system level meter responds → stop → WAV + PCM files in `%LOCALAPPDATA%\PabloCompanion\Recordings/`
6. **Encryption**: Toggle on → record → verify encrypted file → play back decrypted audio
7. **Device handling**: Unplug mic during recording → graceful error message

---

## Open Questions (to resolve during implementation)

1. **AudioCaptureKit Cargo dependency**: Git URL (`pablo-health/AudioCaptureKit`) vs path reference vs publishing to a private registry? Git URL with tag is simplest.
2. **pablo_core.dll size**: Adding WASAPI + audio-capture-core will increase the DLL. Need to verify the `windows` crate features don't bloat excessively (currently uses `windows = "0.62"` with targeted features).
3. **Async vs sync in UniFFI**: `start_capture()` and `stop_capture()` are sync in the Rust traits but may need to be async for UniFFI. The WASAPI captures spawn threads internally, so `start_capture()` returns quickly. `stop_capture()` blocks until finalization — may need `[Async]` in UDL.
