import Foundation
import os

// MARK: - TranscriptionState

enum TranscriptionState: Sendable {
    case running
    case done(transcript: String)
    case pendingUpload(transcript: String)
    case awaitingModel
    case failed(message: String)

    var transcript: String? {
        switch self {
        case let .done(text), let .pendingUpload(text): text
        default: nil
        }
    }

    var isPendingUpload: Bool {
        if case .pendingUpload = self { return true }
        return false
    }
}

// MARK: - TranscriptionViewModel

/// Orchestrates the local transcription pipeline after a session ends.
///
/// Flow:
///   1. `transcribeIfNeeded(_:)` — checks auto-transcribe setting, kicks off pipeline
///   2. Calls pablo-core `transcribeSession1on1` then `renderGoogleMeet`
///   3. Tries to POST the transcript to the backend
///   4. On upload failure: saves encrypted pending file (retry queue)
///   5. `retryPendingUploads()` — called on app launch to flush the queue
@MainActor
@Observable
final class TranscriptionViewModel {
    // MARK: - State

    /// Transcription state keyed by recording ID.
    var states: [UUID: TranscriptionState] = [:]

    /// Number of transcripts waiting to be uploaded.
    var pendingUploadCount = 0

    /// Recordings waiting for a Whisper model download before transcription.
    /// Each entry pairs the recording with the backend session ID (if known).
    var awaitingModelRecordings: [(recording: LocalRecording, sessionId: String?)] = []

    /// Count derived from actual states. Returns 0 if any model is available
    /// (stale `.awaitingModel` entries from before a download completed).
    var awaitingModelCount: Int {
        let manager = ModelManager.shared
        let anyModelAvailable = WhisperModelPreset.allCases.contains {
            manager.isAvailable($0)
        }
        if anyModelAvailable { return 0 }
        return states.values.count(where: {
            if case .awaitingModel = $0 { return true }
            return false
        })
    }

    var errorMessage: String?
    var showError = false

    // MARK: - Dependencies

    var backendURL = "" {
        didSet {
            if URLValidator.validateScheme(backendURL) == nil {
                let token = apiClient.getToken
                apiClient = APIClient(baseURL: backendURL)
                apiClient.getToken = token
            }
        }
    }

    // MARK: - Private

    private var apiClient = APIClient()
    private let store = PendingTranscriptStore()
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "TranscriptionViewModel")

    private var autoTranscribe: Bool {
        UserDefaults.standard.object(forKey: "autoTranscribe") as? Bool ?? true
    }

    private var qualityPreset: WhisperModelPreset {
        let raw = UserDefaults.standard.string(forKey: "qualityPreset") ?? ""
        return WhisperModelPreset(rawValue: raw) ?? .balanced
    }

    /// Configures the API client with a token provider for authenticated requests.
    func configureAuth(getToken: @escaping @Sendable () async throws -> String) {
        apiClient.getToken = getToken
    }

    // MARK: - Public API

    /// Triggers transcription for a recording if auto-transcribe is enabled.
    func transcribeIfNeeded(_ recording: LocalRecording, sessionId: String? = nil) {
        guard autoTranscribe else { return }
        guard recording.micPCMFileURL != nil else {
            logger.info("Skipping transcription: no PCM sidecar for \(recording.id)")
            return
        }
        Task { await transcribe(recording, sessionId: sessionId) }
    }

    /// Unconditionally runs the full transcription pipeline for a recording.
    /// - Parameter sessionId: The backend session UUID. Falls back to recording UUID if nil.
    /// - Parameter presetOverride: If provided, uses this model preset instead of the user's configured quality preset.
    func transcribe(
        _ recording: LocalRecording,
        sessionId: String? = nil,
        using presetOverride: WhisperModelPreset? = nil
    ) async {
        guard let micPath = recording.micPCMFileURL?.path else {
            states[recording.id] = .failed(message: "No mic audio file available")
            return
        }
        let micSize = (try? FileManager.default.attributesOfItem(atPath: micPath)[.size] as? Int) ?? 0
        if micSize == 0 {
            states[recording.id] = .failed(
                message: "Mic audio file is empty (0 bytes) — recording may have stalled"
            )
            logger.warning("Skipping transcription for \(recording.id): mic PCM file is 0 bytes")
            return
        }

        let backendSessionId = sessionId ?? recording.id.uuidString
        states[recording.id] = .running
        logger.info("Starting transcription for \(recording.id) (session: \(backendSessionId))")

        do {
            let config = try buildTranscriptionConfig(using: presetOverride)
            let result = try await transcribeSession1on1(
                sessionId: backendSessionId,
                micPath: micPath,
                systemPath: recording.systemPCMFileURL?.path,
                config: config
            )
            let text = renderGoogleMeet(transcript: result, opts: renderOptions(for: recording))
            logger.info("Transcription complete for \(recording.id), \(result.segments.count) segments")
            await uploadOrQueue(recording: recording, sessionId: backendSessionId, text: text)
        } catch is ModelError {
            states[recording.id] = .awaitingModel
            awaitingModelRecordings.append((recording: recording, sessionId: sessionId))
            logger.info("Transcription deferred for \(recording.id): model not downloaded")
        } catch {
            let message = error.localizedDescription
            states[recording.id] = .failed(message: message)
            logger.error("Transcription failed for \(recording.id): \(message)")
        }
    }

    /// Retry all pending transcripts that failed to upload.
    /// Uses exponential backoff: skips items that have been retried too many times recently.
    /// After 10 retries, stops auto-retrying (manual "Retry Now" still works).
    func retryPendingUploads() async {
        let pending = store.loadAll()
        pendingUploadCount = pending.count
        guard !pending.isEmpty else { return }
        logger.info("Retrying \(pending.count) pending transcript uploads")

        for var item in pending {
            // Exponential backoff: skip items past their retry window
            if item.retryCount > 10 { continue }
            if item.retryCount > 0 {
                let backoffSeconds = min(14400, 300 * Int(pow(2.0, Double(item.retryCount - 1))))
                let elapsed = Date().timeIntervalSince(item.createdAt)
                if elapsed < Double(backoffSeconds) { continue }
            }

            do {
                try await postTranscript(sessionID: item.sessionID, text: item.text)
                store.delete(recordingID: item.recordingID)
                pendingUploadCount = max(0, pendingUploadCount - 1)
                if case let .pendingUpload(text) = states[item.recordingID] {
                    states[item.recordingID] = .done(transcript: text)
                }
                logger.info("Retry upload succeeded for \(item.recordingID)")
            } catch {
                item.retryCount += 1
                store.save(item)
                logger.warning("Retry upload failed for \(item.recordingID): \(error.localizedDescription)")
            }
        }
    }

    /// Force-retry all pending uploads immediately, ignoring backoff. Called by the "Retry Now" button.
    func forceRetryPendingUploads() async {
        let pending = store.loadAll()
        pendingUploadCount = pending.count
        guard !pending.isEmpty else { return }
        logger.info("Force-retrying \(pending.count) pending transcript uploads")

        for var item in pending {
            do {
                try await postTranscript(sessionID: item.sessionID, text: item.text)
                store.delete(recordingID: item.recordingID)
                pendingUploadCount = max(0, pendingUploadCount - 1)
                if case let .pendingUpload(text) = states[item.recordingID] {
                    states[item.recordingID] = .done(transcript: text)
                }
                logger.info("Force retry upload succeeded for \(item.recordingID)")
            } catch {
                item.retryCount += 1
                store.save(item)
                logger.warning("Force retry upload failed for \(item.recordingID): \(error.localizedDescription)")
            }
        }
    }

    /// Re-uploads an existing transcript to the backend (e.g. after a backend processing bug fix).
    func reuploadTranscript(recordingId: UUID, sessionId: String) async {
        guard let text = states[recordingId]?.transcript else {
            logger.warning("No transcript text found for recording \(recordingId)")
            return
        }
        logger.info("Re-uploading transcript for session \(sessionId)")
        do {
            try await postTranscript(sessionID: sessionId, text: text)
            logger.info("Re-upload succeeded for session \(sessionId)")
        } catch {
            logger.error("Re-upload failed for session \(sessionId): \(error.localizedDescription)")
            errorMessage = "Re-upload failed: \(error.localizedDescription)"
            showError = true
        }
    }

    /// Process recordings that were deferred because the Whisper model wasn't available.
    /// Called after a model download completes. Uses the just-downloaded preset so we
    /// don't fail again looking for a different model than what the user downloaded.
    func processAwaitingModelRecordings(downloadedPreset: WhisperModelPreset) async {
        let pending = awaitingModelRecordings
        awaitingModelRecordings.removeAll()
        for entry in pending {
            await transcribe(entry.recording, sessionId: entry.sessionId, using: downloadedPreset)
        }
    }

    // MARK: - Private

    private func buildTranscriptionConfig(
        using presetOverride: WhisperModelPreset? = nil
    ) throws -> TranscriptionConfig {
        let modelURL = try resolveModelURL(preferred: presetOverride ?? qualityPreset)
        return TranscriptionConfig(
            modelPath: modelURL.path,
            micChannels: 1,
            micSampleRate: 48000,
            systemChannels: 2,
            systemSampleRate: 48000,
            swapSpeakers: UserDefaults.standard.bool(forKey: "swapSpeakers")
        )
    }

    /// Resolves a model URL, falling back to any available model if the preferred one isn't found.
    private func resolveModelURL(preferred: WhisperModelPreset) throws -> URL {
        let manager = ModelManager.shared
        if let url = try? manager.modelURL(for: preferred) { return url }
        logger.info("Preferred model \(preferred.modelFileName) not found, checking alternatives")
        for preset in WhisperModelPreset.allCases where preset != preferred {
            if let url = try? manager.modelURL(for: preset) {
                logger.info("Falling back to \(preset.modelFileName)")
                return url
            }
        }
        throw ModelError.notFound(preferred)
    }

    private func renderOptions(for recording: LocalRecording) -> GoogleMeetOptions {
        GoogleMeetOptions(
            sessionDate: recording.createdAt.formatted(date: .long, time: .omitted),
            therapistName: "Therapist",
            clientName: "Client",
            clientAName: "Client A",
            clientBName: "Client B"
        )
    }

    private func uploadOrQueue(recording: LocalRecording, sessionId: String, text: String) async {
        do {
            try await postTranscript(sessionID: sessionId, text: text)
            states[recording.id] = .done(transcript: text)
            logger.info("Transcript uploaded for \(recording.id) (session: \(sessionId))")
        } catch {
            logger.warning("Upload failed, queuing for retry: \(error.localizedDescription)")
            let pending = PendingTranscriptStore.PendingTranscript(
                recordingID: recording.id,
                sessionID: sessionId,
                text: text,
                createdAt: Date(),
                retryCount: 0
            )
            store.save(pending)
            states[recording.id] = .pendingUpload(transcript: text)
            pendingUploadCount += 1
        }
    }

    private func postTranscript(sessionID: String, text: String) async throws {
        let response = try await apiClient.uploadTranscript(
            sessionId: sessionID,
            format: "txt",
            content: text
        )
        logger.info("Transcript uploaded for session \(sessionID), message: \(response.message)")
    }
}
