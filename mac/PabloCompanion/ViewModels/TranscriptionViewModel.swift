import Foundation
import os

// MARK: - TranscriptionState

enum TranscriptionState: Sendable {
    case running
    case done(transcript: String)
    case pendingUpload(transcript: String)
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

    var errorMessage: String?
    var showError = false

    // MARK: - Dependencies

    var backendURL = ""
    var getToken: (() async throws -> String)?

    // MARK: - Private

    private let store = PendingTranscriptStore()
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "TranscriptionViewModel")

    private var autoTranscribe: Bool {
        UserDefaults.standard.object(forKey: "autoTranscribe") as? Bool ?? true
    }

    private var qualityPreset: QualityPreset {
        let raw = UserDefaults.standard.string(forKey: "qualityPreset") ?? ""
        return QualityPreset(rawValue: raw) ?? .balanced
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
    func transcribe(_ recording: LocalRecording) async {
        guard let micPath = recording.micPCMFileURL?.path else {
            states[recording.id] = .failed(message: "No mic audio file available")
            return
        }

        states[recording.id] = .running
        logger.info("Starting transcription for \(recording.id)")

        do {
            let modelURL = try ModelManager.shared.modelURL(for: qualityPreset)

            let config = TranscriptionConfig(
                modelPath: modelURL.path,
                micChannels: 1,
                micSampleRate: 48000,
                systemChannels: 2,
                systemSampleRate: 48000
            )

            let result = try await transcribeSession1on1(
                sessionId: recording.id.uuidString,
                micPath: micPath,
                systemPath: recording.systemPCMFileURL?.path,
                config: config
            )

            let opts = GoogleMeetOptions(
                sessionDate: recording.createdAt.formatted(date: .long, time: .omitted),
                therapistName: "Therapist",
                clientName: "Client",
                clientAName: "Client A",
                clientBName: "Client B"
            )

            let text = renderGoogleMeet(transcript: result, opts: opts)
            logger.info("Transcription complete for \(recording.id), \(result.segments.count) segments")

            await uploadOrQueue(recording: recording, text: text)
        } catch {
            let message = error.localizedDescription
            states[recording.id] = .failed(message: message)
            logger.error("Transcription failed for \(recording.id): \(message)")
        }
    }

    /// Retry all pending transcripts that failed to upload. Call on app launch.
    func retryPendingUploads() async {
        let pending = store.loadAll()
        pendingUploadCount = pending.count
        guard !pending.isEmpty else { return }
        logger.info("Retrying \(pending.count) pending transcript uploads")

        for var item in pending {
            do {
                try await postTranscript(sessionID: item.sessionID, text: item.text)
                store.delete(recordingID: item.recordingID)
                pendingUploadCount = max(0, pendingUploadCount - 1)
                // Restore done state if we have it, else just mark uploaded
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

    // MARK: - Private

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

    private func postTranscript(sessionID _: String, text _: String) async throws {
        // Stub: replace with real APIClient call once backend endpoint is ready.
        // POST /api/sessions/{sessionID}/transcript  body: { "text": "...", "format": "google_meet" }
        guard !backendURL.isEmpty else {
            throw TranscriptionError.backendNotConfigured
        }
        guard let token = try? await getToken?() else {
            throw TranscriptionError.notAuthenticated
        }
        _ = token // will be used in real implementation
        throw TranscriptionError.backendNotReady
    }
}

// MARK: - TranscriptionError

enum TranscriptionError: LocalizedError {
    case backendNotConfigured
    case notAuthenticated
    case backendNotReady

    var errorDescription: String? {
        switch self {
        case .backendNotConfigured: "Backend URL not configured"
        case .notAuthenticated: "Not authenticated"
        case .backendNotReady: "Transcript upload endpoint not yet available"
        }
    }
}
