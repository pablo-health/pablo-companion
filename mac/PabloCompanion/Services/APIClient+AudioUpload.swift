import CompanionSessionCore
import Foundation
import PracticeClientCore

// MARK: - Audio Upload (shared CompanionSessionCore wire path)

extension APIClient {
    /// The shared upload client, bound to this `APIClient`'s auth + device
    /// binding. The same `AudioUploadClient` type is what the headless e2e
    /// harness drives, so the multipart body, the `audio/wav`-on-raw-PCM mime,
    /// and the `INVALID_STATUS` self-heal can't drift between app and test.
    private var audioUploadClient: AudioUploadClient {
        AudioUploadClient(
            baseURLString: baseURLString,
            token: { [self] in try await requireToken() },
            attachBinding: { APIClient.attachDeviceBinding(to: &$0) },
            logSubsystem: AppConstants.appBundleID
        )
    }

    /// Uploads therapist and client audio files to the backend for server-side
    /// transcription.
    ///
    /// - Parameters:
    ///   - sessionId: The backend session UUID (must be in `recording_complete`).
    ///   - therapistAudioURL: Path to the mic PCM/WAV sidecar file.
    ///   - clientAudioURL: Path to the system audio PCM/WAV sidecar (optional).
    ///   - onProgress: Progress callback (0.0-1.0).
    /// - Returns: `AudioUploadResponse` with the session's new status.
    func uploadAudio(
        sessionId: String,
        therapistAudioURL: URL,
        clientAudioURL: URL?,
        sampleRate: Int,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> AudioUploadResponse {
        do {
            return try await audioUploadClient.uploadAudio(
                sessionId: sessionId,
                therapistAudioURL: therapistAudioURL,
                clientAudioURL: clientAudioURL,
                sampleRate: sampleRate,
                onProgress: onProgress
            )
        } catch let error as SessionUploadError {
            throw mapUploadError(error)
        }
    }

    /// Uploads audio with the shared `INVALID_STATUS` self-heal: if the backend
    /// rejects because the session is still `recording`, it is PATCHed to
    /// `recording_complete` and the upload is retried once. This control flow
    /// lives in `CompanionSessionCore` so the harness exercises the same recovery.
    func uploadAudioWithSelfHeal(
        sessionId: String,
        therapistAudioURL: URL,
        clientAudioURL: URL?,
        sampleRate: Int,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> AudioUploadResponse {
        do {
            return try await audioUploadClient.uploadWithSelfHeal(
                sessionId: sessionId,
                therapistAudioURL: therapistAudioURL,
                clientAudioURL: clientAudioURL,
                sampleRate: sampleRate,
                onProgress: onProgress
            )
        } catch let error as SessionUploadError {
            throw mapUploadError(error)
        }
    }

    /// Maps a `CompanionSessionCore.SessionUploadError` back onto the app's
    /// `PabloError` contract, preserving the 401 → `onAuthRejected` side-effect
    /// that the shared error mapper (`mapHTTPErrors`) applies to every other path.
    private func mapUploadError(_ error: SessionUploadError) -> PabloError {
        let message = error.message ?? "Unknown error"
        switch error.statusCode {
        case 401:
            onAuthRejected?(error.code == Self.idleTimeoutCode)
            return .unauthenticated
        case 403:
            return .forbidden
        case 404:
            return .notFound(resource: message)
        case 409:
            return .conflictState(message: message)
        case 426:
            return .updateRequired(message: message)
        default:
            return .apiClient(
                statusCode: UInt16(max(0, error.statusCode)),
                message: message,
                code: error.code
            )
        }
    }
}
