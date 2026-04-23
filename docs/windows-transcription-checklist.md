# Windows Transcription Pipeline — Checklist

Bugs found on macOS that the Windows (C# / WinUI 3) implementation must avoid. These were discovered during real therapist recording sessions and caused silent failures — no errors, just bad output.

> **Note (2026):** this doc was written when both platforms shared a Rust core via UniFFI. That core has since been removed (commit `5f05c87`). macOS now transcribes in the cloud; Windows still uses local Whisper.net (see `PABLO-D-106` for the migration to cloud). The **principles** below (decrypt before transcribe, let sample rate flow, don't hardcode 48 kHz) still apply — only the "Rust via UniFFI" references are outdated; read them as "the current native implementation".

---

## 1. Encrypted PCM Sidecars Must Be Decrypted Before Transcription

**What happened on macOS:** The transcription pipeline passed encrypted `.enc.pcm` file paths directly to the Rust `preprocess_pcm` function. Rust read the ciphertext as raw signed 16-bit LE audio samples. Whisper received noise and hallucinated generic phrases ("Thank you", "Thanks for watching") instead of the actual session content.

**What to check on Windows:**
- [ ] When encryption is enabled, the C# transcription code must decrypt PCM sidecar files to temp files before calling `transcribe_session_1on1` via UniFFI
- [ ] Temp files must be cleaned up after transcription completes (success or failure)
- [ ] The decryption format for PCM sidecars is: sequential `[4-byte UInt32 LE length][AES-GCM sealed box]` chunks — **no** WAV header (unlike the main `.enc.wav` file which has a 44-byte header before the encrypted chunks)
- [ ] Test with encryption both enabled and disabled — unencrypted `.pcm` files should be passed directly without decryption

**macOS fix:** `RecordingEncryptor.decryptPCMToTempFile(at:)` + `TranscriptionViewModel.decryptPCMIfNeeded(_:)` — see commit `fac75f2`.

---

## 2. Sample Rate Must Flow From Audio Capture to Transcription Config

**What happened on macOS:** `TranscriptionConfig` hardcoded `micSampleRate: 48000` and `systemSampleRate: 48000`. When a Bluetooth headset was connected, macOS negotiated HFP mode and the mic dropped to 24000 Hz. The PCM sidecar files were written at 24000 Hz, but Whisper was told they were 48000 Hz. Result: audio played at 2x speed, duration halved, most speech lost.

**What to check on Windows:**
- [ ] The `CaptureRecordingResult` (from Rust via UniFFI) must include `mic_sample_rate: u32` and `system_sample_rate: u32` fields — **these do not exist yet in the UDL definition**, add them
- [ ] The WASAPI capture code must detect the actual negotiated sample rate (especially with Bluetooth devices) and store it in the recording result
- [ ] The C# `RecordingViewModel` (or equivalent) must store the detected sample rate in whatever `LocalRecording` equivalent is used
- [ ] The sample rate must be passed to `TranscriptionConfig` when calling `transcribe_session_1on1` — never hardcode 48000
- [ ] The Rust `preprocess_pcm` function handles any input rate correctly (resamples to 16 kHz for Whisper), so the only requirement is passing the right value

**Windows-specific risk:** WASAPI exclusive mode can negotiate unusual sample rates (44100, 16000, etc.) depending on the audio device. Shared mode typically uses the device's default rate. Both paths must report the actual rate.

---

## 3. System Audio Permission (Windows-Specific)

**What happened on macOS:** macOS 26 (Tahoe) split "Screen & System Audio Recording" into two separate permissions. The process tap API (`AudioHardwareCreateProcessTap`) succeeded and delivered callbacks, but all audio samples were zeros (silence). `CGPreflightScreenCaptureAccess()` returned true (misleading — it only checks Screen Recording, not System Audio Recording). No error was raised anywhere.

**What to check on Windows:**
- [ ] WASAPI loopback capture requires no special permissions on Windows 10/11, but verify this is still true on the target Windows version
- [ ] If Windows introduces audio capture permissions in the future, ensure the app detects and surfaces the issue rather than silently recording silence
- [ ] Add a diagnostic check: if system audio callbacks are firing but RMS level stays at 0 for >5 seconds while the user claims audio is playing, show a warning

---

## 4. Diagnostic Counters Must Be Accessible During Recording

**What was useful on macOS:** The `CaptureSessionDiagnostics` struct with `micCallbackCount`, `systemCallbackCount`, `micFormat`, `systemFormat`, `mixCycles`, and `bytesWritten` was essential for debugging. These are displayed in the Settings > Debug section.

**What to implement on Windows:**
- [ ] Expose equivalent diagnostic counters from the Rust audio capture layer
- [ ] Display them in a debug/settings view in the WinUI app
- [ ] Include the detected sample rate in the mic format diagnostic string (e.g., "24000Hz 1ch")

---

## Summary of Rust Core Changes Needed

The following changes to `core/uniffi/pablo_core.udl` are needed before the Windows transcription pipeline will work correctly:

```
dictionary CaptureRecordingResult {
    // ... existing fields ...
    u32 mic_sample_rate;       // actual mic sample rate (may differ from 48000 with Bluetooth)
    u32 system_sample_rate;    // actual system audio sample rate
};
```

The Rust `preprocess_pcm` and `transcribe_session_1on1` functions already accept variable sample rates — no changes needed there. The issue is purely about making sure the correct rate reaches them.
