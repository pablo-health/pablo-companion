import SwiftUI

extension ContentView {
    /// Launch-time recovery: drain the transcript-text retry queue, sweep the
    /// recordings directory for orphaned audio with a known session linkage,
    /// then drain the audio retry queue. Mirrors the Windows scanner +
    /// `ResumePendingUploadsAsync` (App.xaml.cs:190-212).
    func resumeAllPendingUploads() async {
        await transcriptionVM.retryPendingUploads()
        await adoptAndRetryPendingAudioUploads()
    }

    /// Drain both pending queues — transcript text AND audio. Bound to the
    /// "Retry Now" entry in DayView/SessionHistoryView. Ignores backoff and the
    /// max-retries cap; mirrors the Windows Settings → Retry now button.
    func forceRetryAllPendingUploads() async {
        await transcriptionVM.forceRetryPendingUploads()
        await transcriptionVM.forceRetryPendingAudioUploads()
    }

    /// Stops an in-flight recording and queues its audio for upload without
    /// touching the network. Used when a forced sign-out arrives while a
    /// session is recording (the server has already rejected the session, so
    /// stop-time backend calls could only fail): capture ends, the encrypted
    /// audio stays on disk, and the pending queue drains after re-auth — the
    /// upload's INVALID_STATUS self-heal completes the skipped status PATCH.
    func stopAndQueueActiveRecording() async {
        guard let sessionId = activeSessionId else { return }
        await recordingVM.stopRecording()
        queueSessionAudioForUpload(sessionId)
        recordingVM.clearSessionSegments(sessionId)
    }

    /// Persists every recorded segment of a session into the pending audio
    /// upload queue. Must run while the user is still signed in — the store's
    /// encryption is scoped to the signed-in user, so entries queued after a
    /// sign-out would be dropped. Idempotent per session (re-adding preserves
    /// `createdAt` / `retryCount`), so the stop flow can pre-queue defensively
    /// before its network calls and the upload path re-queues harmlessly.
    func queueSessionAudioForUpload(_ sessionId: String) {
        for segment in recordingVM.allRecordingsForSession(sessionId) {
            guard let micURL = segment.micPCMFileURL else { continue }
            transcriptionVM.enqueuePendingAudioUpload(
                sessionId: sessionId,
                micPath: micURL.path,
                systemPath: segment.systemPCMFileURL?.path,
                isEncrypted: segment.isEncrypted
            )
        }
    }

    /// Picks up recordings whose ID maps back to a known session via
    /// `sessionRecordingMap` and enqueues them into `PendingAudioUploadStore`,
    /// then drives the audio retry loop. Orphans without a session linkage
    /// keep their existing manual-attach UX from session detail.
    func adoptAndRetryPendingAudioUploads() async {
        let orphans = recordingVM.orphanedRecordings()
        if !orphans.isEmpty {
            let recordingToSession = Dictionary(
                uniqueKeysWithValues: recordingVM.sessionRecordingMap.map { ($1, $0) }
            )
            for orphan in orphans {
                guard let sessionId = recordingToSession[orphan.id] else { continue }
                guard let micURL = orphan.micPCMFileURL else { continue }
                transcriptionVM.enqueuePendingAudioUpload(
                    sessionId: sessionId,
                    micPath: micURL.path,
                    systemPath: orphan.systemPCMFileURL?.path,
                    isEncrypted: orphan.isEncrypted
                )
            }
        }
        await transcriptionVM.retryPendingAudioUploads()
    }
}
