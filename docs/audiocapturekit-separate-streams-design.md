# AudioCaptureKit: Separate Audio Streams — Design Document

_Created: 2026-03-03_
_Status: READY FOR IMPLEMENTATION_
_Target repo: pablo-health/AudioCaptureKit_

---

## 1. Context

AudioCaptureKit is a first-party Pablo framework used in Pablo Companion (and potentially other products) to record therapy sessions on macOS. Currently it captures mic + system audio and writes both streams into a single mixed WAV file.

The Pablo transcription pipeline needs these streams **separated** so that:
- The mic file (therapist's voice) can be transcribed with a known speaker identity
- The system audio file (remote participant voices) can be transcribed and diarized independently
- Stereo system audio is preserved for high-quality human playback

AudioCaptureKit's job is simply to **capture at the best quality it can and write separate files**. It does not resample, mix, or do any ML processing. Downstream consumers (Rust core, ASR pipeline) handle resampling and channel manipulation.

---

## 2. Current API (as observed in pablo-companion)

```swift
// CaptureConfiguration
let config = CaptureConfiguration(
    sampleRate: 48000,
    bitDepth: 16,
    channels: 2,           // currently mixes mic + system into 2-ch file
    encryptor: encryptor,
    outputDirectory: recordingsDirectory,
    micDeviceID: selectedMicID,
    enableMicCapture: true,
    enableSystemCapture: true
)

// RecordingResult (returned by stopCapture())
result.fileURL        // single WAV file (mic + system mixed)
result.duration       // TimeInterval
result.metadata.id    // UUID
result.metadata.isEncrypted // Bool
result.checksum       // String (integrity check)
```

---

## 3. Requirements

### 3.1 New Behavior: Separate Output Files

When configured for separate output, AudioCaptureKit must write **two files**:

| File | Channels | Content | Format |
|------|----------|---------|--------|
| Mic file | **1 (mono)** | Microphone input only — no system audio | 48 kHz, 16-bit PCM WAV |
| System audio file | **2 (stereo)** | System/loopback audio only — no mic | 48 kHz, 16-bit PCM WAV |

**Key principle:** Capture at full quality, do not downsample. Consumers decide what to do with the audio.

### 3.2 File Naming

Use the same base naming convention as the existing single-file mode, with suffixes:

```
<existing_base_name>_mic.wav       // microphone
<existing_base_name>_system.wav    // system audio
```

Example: if the existing convention produces `recording-2026-03-03T14-30-00.wav`, produce:
```
recording-2026-03-03T14-30-00_mic.wav
recording-2026-03-03T14-30-00_system.wav
```

### 3.3 Encryption

If an encryptor is provided, **both files** are encrypted independently. Each file gets its own encrypted output.

### 3.4 Checksums

Each file gets its own checksum for integrity verification (HIPAA compliance requires this).

### 3.5 Backward Compatibility

The default behavior is **unchanged**. Existing callers passing no `streamMode` get the current single-file combined output. No existing code in pablo-companion or other consumers should break.

### 3.6 Partial Capture

Handle gracefully:
- If only mic capture is enabled → produce only mic file
- If only system capture is enabled → produce only system file
- If neither system audio is available (user hasn't granted permission) → proceed with mic-only, no system file

---

## 4. Proposed API Changes

### 4.1 New Enum: `AudioStreamMode`

```swift
/// Controls whether AudioCaptureKit mixes audio streams into one file
/// or writes each source to a separate file.
public enum AudioStreamMode: Sendable {
    /// Mic and system audio are mixed into a single stereo WAV file.
    /// This is the existing behavior and the default.
    case combined

    /// Mic and system audio are written as separate files.
    /// Mic: mono WAV.  System audio: stereo WAV.
    /// fileURL in RecordingResult points to the mic file.
    /// systemAudioFileURL in RecordingResult points to the system audio file.
    case separateFiles
}
```

### 4.2 Updated `CaptureConfiguration`

Add one new property. All existing properties and their defaults are unchanged.

```swift
public struct CaptureConfiguration: Sendable {
    // --- EXISTING PROPERTIES (unchanged) ---
    public var sampleRate: Int
    public var bitDepth: Int
    public var channels: Int
    public var encryptor: (any RecordingEncryptor)?
    public var outputDirectory: URL
    public var micDeviceID: String?
    public var enableMicCapture: Bool
    public var enableSystemCapture: Bool

    // --- NEW PROPERTY ---
    /// Controls whether mic and system audio are written to a single file
    /// (combined, existing behavior) or two separate files.
    /// Default: .combined (preserves backward compatibility)
    public var streamMode: AudioStreamMode = .combined

    // Existing init remains unchanged — new property uses default value
}
```

### 4.3 Updated `RecordingResult`

Add one new optional property. All existing properties are unchanged.

```swift
public struct RecordingResult: Sendable {
    // --- EXISTING PROPERTIES (unchanged) ---
    /// Primary output file.
    /// - In .combined mode: the single mixed WAV file (existing behavior).
    /// - In .separateFiles mode: the microphone-only WAV file.
    public let fileURL: URL

    public let duration: TimeInterval
    public let metadata: RecordingMetadata
    public let checksum: String  // checksum of fileURL

    // --- NEW PROPERTIES ---
    /// System audio output file. Only present when streamMode == .separateFiles
    /// AND system audio was successfully captured.
    /// nil in .combined mode or if no system audio was captured.
    public let systemAudioFileURL: URL?

    /// Checksum of systemAudioFileURL. nil when systemAudioFileURL is nil.
    public let systemAudioChecksum: String?
}
```

### 4.4 No Other API Changes

- `CompositeCaptureSession` public interface is unchanged
- `AudioCaptureDelegate` protocol is unchanged
- `CaptureState`, `AudioLevels`, `CaptureError`, `AudioSource` are unchanged
- All existing initializers continue to work

---

## 5. Internal Implementation Guidance

> Note: This section is for the implementer. The public API is what matters; implementation details may vary.

### 5.1 Recording Architecture

In `.combined` mode (existing): a single `AVAudioFile` or similar writer receives mixed audio.

In `.separateFiles` mode (new):
- Maintain two separate audio writers: one for mic, one for system audio
- Write mic samples only to the mic writer
- Write system audio samples only to the system audio writer
- Do not cross-contaminate streams

### 5.2 Channel Configuration

In `.separateFiles` mode, the `channels` parameter in `CaptureConfiguration` applies to the **combined** mode only (for backward compat). In separate mode:
- Mic file: always 1 channel (mono)
- System file: always 2 channels (stereo)

The implementer may choose to ignore the `channels` value in `.separateFiles` mode or derive the channel count from the capture source.

### 5.3 Silence / No Capture

In `.separateFiles` mode:
- If `enableMicCapture = false` → no mic file produced → `fileURL` should still be valid but contains silence or an empty duration, OR return a meaningful error. **Preferred:** if mic is the primary file, treat a disabled mic as an error in `.separateFiles` mode.
- If `enableSystemCapture = false` OR system audio is unavailable → `systemAudioFileURL = nil`, `systemAudioChecksum = nil`. This is not an error.

### 5.4 Timing Alignment

Both files must share the same start timestamp and session ID so that consumers can align them. The `metadata.id` (UUID) must be identical in both files' metadata.

### 5.5 Encryption

If an encryptor is provided:
1. Write the raw WAV to a temp file
2. Encrypt the temp file → final output file
3. Delete the temp file
4. Repeat for each file (mic, system) independently

### 5.6 Checksum

Compute checksum over the final output file bytes (after encryption if encrypted). Use the same checksum algorithm as the existing implementation.

---

## 6. How pablo-companion Uses This

After this change, `RecordingService.swift` in pablo-companion will be updated to:

```swift
let config = CaptureConfiguration(
    sampleRate: 48000,
    bitDepth: 16,
    channels: 2,         // only relevant for .combined (ignored in .separateFiles)
    encryptor: encryptor,
    outputDirectory: recordingsDirectory,
    micDeviceID: selectedMicID,
    enableMicCapture: true,
    enableSystemCapture: true,
    streamMode: .separateFiles   // NEW
)
```

And `RecordingService` will receive:
```swift
let result = try await session.stopCapture()
result.fileURL              // mic file (therapist)
result.systemAudioFileURL   // system audio file (client(s)), may be nil
result.checksum             // mic file checksum
result.systemAudioChecksum  // system audio checksum, may be nil
```

The pablo-companion `LocalRecording` model will be updated to store both URLs. The AudioCaptureKit design doc does not need to specify those downstream changes.

---

## 7. Testing Requirements

### 7.1 Unit Tests

- `.combined` mode produces a single file (existing behavior unchanged)
- `.separateFiles` mode with both sources enabled: produces two files, mic is mono, system is stereo
- `.separateFiles` mode with system audio unavailable: produces mic file only, `systemAudioFileURL` is nil
- `.separateFiles` mode with encryption: both files are encrypted, checksums are valid
- File naming: mic file ends with `_mic.wav`, system file ends with `_system.wav`
- Both files share the same `metadata.id`
- Duration of both files matches the session duration

### 7.2 Manual / Integration Tests

- Record a real session (requires mic + screen recording permission)
- Verify mic file contains only mic audio (no echo of system audio)
- Verify system file contains only system audio (no mic bleed)
- Verify both files play back correctly in QuickTime / AVFoundation
- Verify checksum validation passes for both files
- Verify encrypted files decrypt correctly

---

## 8. Definition of Done

- [ ] `AudioStreamMode` enum is public and documented
- [ ] `CaptureConfiguration.streamMode` added with default `.combined`
- [ ] `RecordingResult.systemAudioFileURL` and `systemAudioChecksum` added as optionals
- [ ] `.combined` mode behavior is byte-for-byte identical to the existing implementation (no regression)
- [ ] `.separateFiles` mode produces correct mono mic file and stereo system file
- [ ] Encryption works for both files in `.separateFiles` mode
- [ ] File naming follows `_mic` / `_system` suffix convention
- [ ] Both files share the same `metadata.id`
- [ ] All unit tests pass
- [ ] `make check` (or equivalent) passes with zero warnings
