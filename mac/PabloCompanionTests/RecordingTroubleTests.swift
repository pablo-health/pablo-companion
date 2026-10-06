import CompanionSessionCore
import Foundation
@testable import Pablo
import Testing

/// The shipping window has to tell a clinician when a session's audio is being
/// lost: capture stalled, capture stopped, or audio that hasn't uploaded.
@Suite("Recording trouble in the main window")
@MainActor
struct RecordingTroubleTests {
    private func recordingSession() -> RecordingViewModel {
        let viewModel = RecordingViewModel()
        viewModel.activeSessionId = "session-1"
        viewModel.service.onCaptureStateUpdate?(.recording, nil)
        return viewModel
    }

    @Test func aHealthyRecordingHasNoTrouble() {
        let viewModel = recordingSession()

        #expect(viewModel.trouble == nil)
    }

    @Test func aStallFromTheWatchdogShowsAsStalled() {
        let viewModel = recordingSession()

        viewModel.service.onRecordingStalled?()

        #expect(viewModel.trouble == .stalled)
    }

    @Test func aStallClearsWhenAudioResumes() {
        let viewModel = recordingSession()
        viewModel.service.onRecordingStalled?()

        viewModel.service.onRecordingResumed?()

        #expect(viewModel.trouble == nil)
    }

    @Test func aMicDisconnectShowsCaptureAsStopped() {
        let viewModel = recordingSession()

        // The service stops capture, then reports the disconnect.
        viewModel.service.onCaptureStateUpdate?(.idle, nil)
        viewModel.service.onMicDisconnectedDuringRecording?()

        #expect(viewModel.trouble == .stopped(RecordingViewModel.micDisconnectedMessage))
        #expect(viewModel.showError)
    }

    @Test func aMicDisconnectTakesRecordingOffTheCard() {
        let viewModel = recordingSession()
        viewModel.service.onCaptureStateUpdate?(.idle, nil)
        viewModel.service.onMicDisconnectedDuringRecording?()

        let label = MinimalMainView.captureStateLabel(state: viewModel.recordingState, trouble: viewModel.trouble)

        #expect(label == "Not recording")
    }

    @Test func aCaptureFailureShowsCaptureAsStoppedWithItsReason() {
        let viewModel = recordingSession()

        viewModel.service.onCaptureStateUpdate?(.idle, nil)
        viewModel.service.onError?("The capture failed.")

        #expect(viewModel.trouble == .stopped("The capture failed."))
    }

    @Test func theMomentBeforeCaptureStartsIsNotTrouble() {
        // The session is open and capture hasn't started yet: idle, no reason.
        let viewModel = RecordingViewModel()
        viewModel.activeSessionId = "session-1"

        #expect(viewModel.trouble == nil)
    }

    @Test func aStoppedCaptureWithNoOpenSessionIsNotTrouble() {
        let viewModel = recordingSession()
        viewModel.service.onCaptureStateUpdate?(.idle, nil)
        viewModel.service.onMicDisconnectedDuringRecording?()

        viewModel.activeSessionId = nil

        #expect(viewModel.trouble == nil)
    }

    @Test func restartingClearsTheTrouble() async {
        let viewModel = recordingSession()
        viewModel.service.onCaptureStateUpdate?(.idle, nil)
        viewModel.service.onMicDisconnectedDuringRecording?()

        await viewModel.retryCapture()

        #expect(!viewModel.micDisconnected)
        #expect(viewModel.trouble == nil)
    }

    @Test func aPausedOrStalledCardStillReadsAsWhatItIs() {
        #expect(MinimalMainView.captureStateLabel(state: .paused, trouble: nil) == "Paused")
        #expect(MinimalMainView.captureStateLabel(state: .recording, trouble: .stalled) == "Recording")
        #expect(MinimalMainView.captureStateLabel(state: .recording, trouble: nil) == "Recording")
    }
}

@Suite("Audio waiting to upload")
struct UploadBacklogTests {
    private static func entry(
        _ sessionId: String,
        state: String = "pendingUpload",
        retryCount: Int = 0
    ) throws -> PendingAudioUploadStore.PendingAudioUpload {
        let json = """
        {"sessionId": "\(sessionId)", "micPath": "/tmp/\(sessionId).pcm", "isEncrypted": true,
         "createdAt": 0, "retryCount": \(retryCount), "state": "\(state)"}
        """
        return try JSONDecoder().decode(PendingAudioUploadStore.PendingAudioUpload.self, from: Data(json.utf8))
    }

    @Test func nothingQueuedShowsNothing() {
        let backlog = UploadBacklog(entries: [])

        #expect(backlog.waiting == 0)
        #expect(backlog.message == nil)
    }

    @Test func aQueuedUploadIsWaiting() throws {
        let backlog = try UploadBacklog(entries: [Self.entry("a")])

        #expect(backlog.waiting == 1)
        #expect(!backlog.hasFailed)
        #expect(backlog.message == "Audio from 1 session hasn’t uploaded yet.")
    }

    @Test func aFailedAttemptMarksTheBacklogFailed() throws {
        let backlog = try UploadBacklog(entries: [Self.entry("a"), Self.entry("b", retryCount: 2)])

        #expect(backlog.waiting == 2)
        #expect(backlog.hasFailed)
        #expect(backlog.message == "Audio from 2 sessions hasn’t uploaded yet.")
    }

    @Test func audioAlreadyUploadedAndWaitingForItsNoteIsNotCounted() throws {
        let backlog = try UploadBacklog(entries: [Self.entry("a", state: "awaitingNote", retryCount: 3)])

        #expect(backlog.waiting == 0)
        #expect(!backlog.hasFailed)
    }
}
