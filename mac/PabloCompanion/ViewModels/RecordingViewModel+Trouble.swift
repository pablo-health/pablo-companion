import Foundation

/// Something wrong with the capture of an open session that the clinician has
/// to see: either no audio is arriving, or capture has stopped while the
/// session is still open. Either way the session's audio is being lost.
enum RecordingTrouble: Equatable {
    /// Capture is running but the mic file has stopped growing (the watchdog).
    case stalled
    /// Capture has stopped while the session is still open, for this reason.
    case stopped(String)

    static let stalledMessage = "No new audio has been recorded in the last minute."
}

extension RecordingViewModel {
    static let micDisconnectedMessage = "Recording stopped because the microphone was disconnected."

    /// What the session card has to say about capture, or nil when recording is
    /// fine or no session is open.
    ///
    /// "Stopped" needs a reason, not just an idle state: the state is also idle
    /// for the moment between a session opening and capture starting, and the
    /// card must not call that a failure. Every way capture stops on its own
    /// leaves one: a mic disconnect sets `micDisconnected`, and a failed start
    /// or a capture failure sets `persistentError`.
    var trouble: RecordingTrouble? {
        guard activeSessionId != nil else { return nil }
        switch recordingState {
        case .idle:
            if micDisconnected { return .stopped(Self.micDisconnectedMessage) }
            return persistentError.map(RecordingTrouble.stopped)
        case .recording:
            return recordingStalled ? .stalled : nil
        case .paused:
            return nil
        }
    }
}
