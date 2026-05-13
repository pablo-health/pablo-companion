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
