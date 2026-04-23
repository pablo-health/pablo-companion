# Windows Transcription — Cloud-Only

As of April 2026, Windows matches macOS: **transcription runs in the Pablo
cloud, not on-device.** The client just records encrypted audio, uploads it to
`POST /api/sessions/{id}/upload-audio`, and the backend produces the transcript
plus SOAP note.

There is no local model download, no on-device Whisper inference, and no
quality preset on Windows. The legacy "transitional local Whisper.net" path
and the Rust/UniFFI-era bug checklist that lived in this file are gone —
none of their failure modes apply when inference is server-side.

## What the client does

1. `RecordingService` writes mic + optional system audio as AES-GCM encrypted
   PCM sidecars (`.enc.pcm`).
2. On session end, `SessionViewModel.EndSessionAsync` enqueues the session in
   `PendingTranscriptionStore` and calls `TranscriptionViewModel.UploadAudioAsync`.
3. `PcmDecryptor.PrepareForUploadAsync` decrypts the sidecars to a temp file
   (when encrypted) — mirrors macOS `RecordingEncryptor.decryptPCMToTempFile`.
4. `APIClient.UploadAudioAsync` POSTs `multipart/form-data` to
   `/api/sessions/{id}/upload-audio` with `therapist_audio` and optional
   `client_audio` parts. The temp files are cleaned up in the `finally` block.
5. On failure the session stays in the pending queue; `ResumePendingUploadsAsync`
   retries on next launch with exponential backoff (5 min → 4 h, max 10
   attempts), matching the macOS retry policy.
6. `PendingTranscriptionStore` is AES-GCM encrypted with the per-user device
   key and carries the audio paths inline, so pending uploads survive
   sign-out → sign-in (the recording store is wiped, the pending one is not).

## Backend contract

See `docs/companion-api-contract.md`. No new endpoints are required beyond
the existing `upload-audio` endpoint that macOS already uses.

## Tracking

Closed out by PR feat/windows-cloud-transcription (PABLO-D-106).
