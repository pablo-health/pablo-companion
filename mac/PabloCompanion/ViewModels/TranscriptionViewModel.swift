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
    var awaitingModelRecordings: [LocalRecording] = []

    /// Count derived from actual states — avoids stale banner when state transitions happen.
    var awaitingModelCount: Int {
        states.values.count(where: {
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
    func transcribeIfNeeded(_ recording: LocalRecording) {
        guard autoTranscribe else { return }
        guard recording.micPCMFileURL != nil else {
            logger.info("Skipping transcription: no PCM sidecar for \(recording.id)")
            return
        }
        Task { await transcribe(recording) }
    }

    /// Unconditionally runs the full transcription pipeline for a recording.
    /// - Parameter presetOverride: If provided, uses this model preset instead of the user's configured quality preset.
    func transcribe(_ recording: LocalRecording, using presetOverride: WhisperModelPreset? = nil) async {
        guard let micPath = recording.micPCMFileURL?.path else {
            states[recording.id] = .failed(message: "No mic audio file available")
            return
        }

        states[recording.id] = .running
        logger.info("Starting transcription for \(recording.id)")

        do {
            let config = try buildTranscriptionConfig(using: presetOverride)
            let result = try await transcribeSession1on1(
                sessionId: recording.id.uuidString,
                micPath: micPath,
                systemPath: recording.systemPCMFileURL?.path,
                config: config
            )
            let text = renderGoogleMeet(transcript: result, opts: renderOptions(for: recording))
            logger.info("Transcription complete for \(recording.id), \(result.segments.count) segments")
            await uploadOrQueue(recording: recording, text: text)
        } catch is ModelError {
            states[recording.id] = .awaitingModel
            awaitingModelRecordings.append(recording)
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

    /// Process recordings that were deferred because the Whisper model wasn't available.
    /// Called after a model download completes. Uses the just-downloaded preset so we
    /// don't fail again looking for a different model than what the user downloaded.
    func processAwaitingModelRecordings(downloadedPreset: WhisperModelPreset) async {
        let pending = awaitingModelRecordings
        awaitingModelRecordings.removeAll()
        for recording in pending {
            await transcribe(recording, using: downloadedPreset)
        }
    }

    // MARK: - Private

    private func buildTranscriptionConfig(
        using presetOverride: WhisperModelPreset? = nil
    ) throws -> TranscriptionConfig {
        let preset = presetOverride ?? qualityPreset
        let modelURL = try ModelManager.shared.modelURL(for: preset)
        return TranscriptionConfig(
            modelPath: modelURL.path,
            micChannels: 1,
            micSampleRate: 48000,
            systemChannels: 2,
            systemSampleRate: 48000,
            swapSpeakers: UserDefaults.standard.bool(forKey: "swapSpeakers")
        )
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

    private func uploadOrQueue(recording: LocalRecording, text: String) async {
        do {
            try await postTranscript(sessionID: recording.id.uuidString, text: text)
            states[recording.id] = .done(transcript: text)
            logger.info("Transcript uploaded for \(recording.id)")
        } catch {
            logger.warning("Upload failed, queuing for retry: \(error.localizedDescription)")
            let pending = PendingTranscriptStore.PendingTranscript(
                recordingID: recording.id,
                sessionID: recording.id.uuidString,
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
            format: "google_meet",
            content: text
        )
        logger.info("Transcript uploaded for session \(sessionID), message: \(response.message)")
    }
}
