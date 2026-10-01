/// Sessions whose audio is being uploaded right now, shared by every
/// `PendingAudioUploadCoordinator` the app builds.
///
/// A queued entry stays `pendingUpload` for the whole time it is being sent, so
/// without this the 5-minute retry tick, the launch drain and "Retry now" each
/// saw it as due and started another full upload of the same session alongside
/// the first. On a slow uplink the copies split the bandwidth, each got slower,
/// more piled up, and a long session never finished uploading at all.
public actor InFlightUploads {
    private var sessionIds: Set<String> = []

    public init() {}

    /// Marks `sessionId` as uploading. Returns false if it already was, in which
    /// case the caller must not start another upload.
    func claim(_ sessionId: String) -> Bool {
        sessionIds.insert(sessionId).inserted
    }

    func release(_ sessionId: String) {
        sessionIds.remove(sessionId)
    }

    func contains(_ sessionId: String) -> Bool {
        sessionIds.contains(sessionId)
    }
}
