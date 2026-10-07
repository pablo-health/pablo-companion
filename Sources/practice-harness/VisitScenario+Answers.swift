#if canImport(CompanionAuthCore)

import CompanionSessionCore
import Foundation

/// The two answers a client can give on the recording, each run the way the
/// app runs it (`ContentView+RecordingConsent.answerOnRecording`).
extension VisitDriver {
    // MARK: - Agree

    func agree(
        token: String, visit: Visit, sessionID: String, consent: RecordingConsentClient
    ) async throws -> [GateCheck] {
        var checks: [GateCheck] = []

        // The answer is given while recording, once the clinician has read
        // the script aloud.
        let answer = AiConsentAnswer(
            decision: AiConsentEntry.consented,
            modality: .telehealth,
            consentedBy: .client,
            clientStatedLocation: "At home"
        )
        let recording = try await capture.record(touch: touch(token)) {
            try await consent.record(answer, patientId: visit.patientId)
        }
        checks += recording.checks(seconds: capture.seconds)

        let stored = try await send("GET", "/api/patients/\(visit.patientId)/ai-consent", token)
        let current = (stored.json?["current"] as? [String: Any]) ?? [:]
        checks.append(GateCheck(
            name: "answer saved: agreed, telehealth, by the client",
            ok: current["decision"] as? String == "consented"
                && current["modality"] as? String == "telehealth"
                && current["consented_by"] as? String == "client",
            detail: "decision=\(current["decision"] ?? "nil") modality=\(current["modality"] ?? "nil") "
                + "consented_by=\(current["consented_by"] ?? "nil")"
        ))
        let after = try await consent.check(appointmentId: visit.appointmentId)
        checks.append(GateCheck(
            name: "after agreeing, the client reads as clear",
            ok: after.consent == .clear,
            detail: "\(after.consent)"
        ))

        // Stop: the app ends the session (recording_complete), then queues
        // and uploads the audio.
        let ended = try await send(
            "PATCH", "/api/sessions/\(sessionID)/status", token, json: ["status": "recording_complete"]
        )
        checks.append(GateCheck(
            name: "session recording_complete",
            ok: ended.status == 200,
            detail: "HTTP \(ended.status)"
        ))

        checks += try await uploadToNote(recording, sessionID: sessionID, token: token)
        return checks
    }

    /// Queues the recording and drains it as the app does: upload, keep the
    /// audio while the note is drafted, poll to the SOAP, then delete.
    private func uploadToNote(
        _ recording: FixtureCapture.Outcome, sessionID: String, token: String
    ) async throws -> [GateCheck] {
        var checks: [GateCheck] = []
        var store = PendingAudioUploadStore(
            directory: recording.directory.deletingLastPathComponent()
                .appendingPathComponent("queue-\(UUID().uuidString)", isDirectory: true),
            makeEncryptor: { _ in PassthroughEncryptor() }
        )
        store.userEmail = "harness@pablo.health"
        store.add(
            sessionId: sessionID,
            micPath: recording.micURL.path,
            systemPath: recording.systemURL?.path,
            mixedPath: recording.mixedURL.path,
            isEncrypted: false,
            sampleRate: 48000
        )

        let uploadStatus = Box<String?>(nil)
        let uploadError = Box<Error?>(nil)
        let coordinator = appCoordinator(store: store, token: token, status: uploadStatus, error: uploadError)

        let uploaded = await coordinator.forceDrain(only: sessionID)
        if let error = uploadError.value as? SessionUploadError, error.statusCode == 501 {
            checks.append(SoapGate.transcriptionOffCheck(allowed: allowTranscriptionOff))
            return checks
        }
        if let error = uploadError.value {
            throw error
        }
        checks.append(GateCheck(
            name: "upload accepted + transcribing",
            ok: uploaded == 1 && uploadStatus.value == "transcribing",
            detail: "status \(uploadStatus.value ?? "none")"
        ))
        let audio = [recording.mixedURL, recording.micURL] + [recording.systemURL].compactMap(\.self)
        let keptWhileWaiting = audio.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        let waitingState = store.get(sessionId: sessionID).map { "\($0.state)" } ?? "none"
        checks.append(GateCheck(
            name: "audio kept until the note exists",
            ok: keptWhileWaiting && store.get(sessionId: sessionID)?.state == .awaitingNote,
            detail: "state \(waitingState), " + (keptWhileWaiting ? "files on disk" : "files missing")
        ))

        try await checks.append(
            SoapGate(client: client, idToken: token, pollSeconds: pollSeconds).poll(sessionID: sessionID)
        )

        let confirmed = await coordinator.reconcile()
        let left = audio.filter { FileManager.default.fileExists(atPath: $0.path) }
        let queued = store.get(sessionId: sessionID) != nil
        checks.append(GateCheck(
            name: "local audio deleted after the note",
            ok: confirmed == 1 && left.isEmpty && !queued,
            detail: "confirmed \(confirmed), \(left.count) file(s) left, queue "
                + (queued ? "still holds the session" : "empty")
        ))
        return checks
    }

    /// The coordinator as the app wires it (`TranscriptionViewModel.coordinator`):
    /// the audio is deleted only once the backend has the note, never on the
    /// upload's acknowledgement.
    private func appCoordinator(
        store: PendingAudioUploadStore, token: String, status: Box<String?>, error: Box<Error?>
    ) -> PendingAudioUploadCoordinator {
        let uploadClient = AudioUploadClient(baseURLString: baseURL, token: { token }, attachBinding: binding)
        let client = client
        return PendingAudioUploadCoordinator(
            store: store,
            upload: { entry in
                do {
                    let uploaded = try await uploadClient.uploadWithSelfHeal(
                        sessionId: entry.sessionId,
                        therapistAudioURL: URL(fileURLWithPath: entry.micPath),
                        clientAudioURL: entry.systemPath.map { URL(fileURLWithPath: $0) },
                        sampleRate: Int(entry.sampleRate ?? 48000)
                    )
                    status.value = uploaded.status
                } catch let failure {
                    error.value = failure
                    throw failure
                }
            },
            cleanup: { entry in
                RecordingCleaner.removeAudio(
                    micPath: entry.micPath,
                    systemPath: entry.systemPath,
                    mixedPath: entry.mixedPath ?? RecordingCleaner.siblingMixedFile(forMicPath: entry.micPath)
                )
            },
            checkOutcome: { sessionId in
                let session = try await client.request("GET", path: "/api/sessions/\(sessionId)", idToken: token)
                switch session.json?["status"] as? String {
                case "pending_review", "finalized": return .noteReady
                case "failed": return .failed
                default: return .stillWorking
                }
            }
        )
    }

    // MARK: - Decline

    func decline(
        token: String, visit: Visit, sessionID: String, consent: RecordingConsentClient
    ) async throws -> [GateCheck] {
        // The client says no partway in. The app's decline stops the capture
        // first, so the recording is the first half of the visit.
        let half = FixtureCapture(
            micFixture: capture.micFixture, systemFixture: capture.systemFixture, seconds: capture.seconds / 2
        )
        let recording = try await half.record(touch: touch(token))
        var checks = recording.checks(seconds: half.seconds)

        // The app's decline (`discardDeclinedRecording`, then the answer):
        // discard, return the session to a hand-written note, save the answer.
        checks += await discardDeclined(recording, sessionID: sessionID)
        let handWritten = try await send(
            "PATCH", "/api/sessions/\(sessionID)/status", token, json: ["status": "scheduled"]
        )
        try await consent.record(
            AiConsentAnswer(decision: AiConsentEntry.declined, modality: .telehealth, consentedBy: .client),
            patientId: visit.patientId
        )

        let session = try await send("GET", "/api/sessions/\(sessionID)", token)
        let status = session.json?["status"] as? String
        checks.append(GateCheck(
            name: "session back to a hand-written note, never transcribing",
            ok: handWritten.status == 200 && status == "scheduled",
            detail: "PATCH HTTP \(handWritten.status), status now \(status ?? "nil")"
        ))

        let declinedRead = try await consent.check(appointmentId: visit.appointmentId)
        let readsDeclined = if case .declined = declinedRead.consent { true } else { false }
        checks.append(GateCheck(
            name: "the client reads as declined",
            ok: readsDeclined,
            detail: "\(declinedRead.consent)"
        ))

        let later = try await seedVisit(token: token, patientId: visit.patientId)
        let laterStart = try await send(
            "POST", "/api/appointments/\(later.appointmentId)/start-session", token,
            raw: RecordingConsentClient.startSessionBody(askingConsentOnRecording: true)
        )
        checks.append(GateCheck(
            name: "a later recorded start is refused (CLIENT_DECLINED_AI_NOTES)",
            ok: RecordingConsent.declinedOn(statusCode: laterStart.status, body: laterStart.body) != nil,
            detail: "HTTP \(laterStart.status) \(laterStart.bodyPrefix)"
        ))
        return checks
    }

    /// Runs `RecordingCleaner.discardDeclined` against the worst case it has to
    /// undo — the stop already filed the recording under the session and
    /// queued its upload — then checks a launch-time drain finds nothing to
    /// send and no audio is left.
    private func discardDeclined(_ recording: FixtureCapture.Outcome, sessionID: String) async -> [GateCheck] {
        let stateDir = recording.directory.deletingLastPathComponent()
            .appendingPathComponent("state-\(UUID().uuidString)", isDirectory: true)
        var recordingStore = SessionRecordingStore(
            directory: stateDir.appendingPathComponent("recordings"), makeEncryptor: { _ in PassthroughEncryptor() }
        )
        recordingStore.userEmail = "harness@pablo.health"
        var uploadStore = PendingAudioUploadStore(
            directory: stateDir.appendingPathComponent("pending"), makeEncryptor: { _ in PassthroughEncryptor() }
        )
        uploadStore.userEmail = "harness@pablo.health"
        recordingStore.save(sessionId: sessionID, entry: SessionRecordingStore.RecordingEntry(
            recordingID: UUID(),
            fileURL: recording.mixedURL.path,
            duration: capture.seconds / 2,
            createdAt: Date(),
            isEncrypted: false,
            checksum: "",
            channelLayout: "separated",
            micPCMFilePath: recording.micURL.path,
            systemPCMFilePath: recording.systemURL?.path,
            sampleRate: 48000
        ))
        uploadStore.add(
            sessionId: sessionID,
            micPath: recording.micURL.path,
            systemPath: recording.systemURL?.path,
            mixedPath: recording.mixedURL.path,
            isEncrypted: false,
            sampleRate: 48000
        )

        RecordingCleaner.discardDeclined(
            sessionId: sessionID,
            audio: [SessionAudioPaths(
                mixedPath: recording.mixedURL.path,
                micPath: recording.micURL.path,
                systemPath: recording.systemURL?.path
            )],
            recordingStore: recordingStore,
            uploadStore: uploadStore
        )

        let attempts = Box(0)
        await PendingAudioUploadCoordinator(
            store: uploadStore,
            upload: { _ in attempts.value += 1 },
            cleanup: { _ in }
        ).forceDrain()
        let queued = uploadStore.loadAll().count
        let mapped = recordingStore.loadAll()[sessionID] != nil
        let left = FixtureCapture.audioFiles(under: recording.directory)
        return [
            GateCheck(
                name: "nothing queued or uploaded",
                ok: attempts.value == 0 && queued == 0 && !mapped,
                detail: "\(attempts.value) upload attempt(s), \(queued) queued, "
                    + "map entry \(mapped ? "still there" : "gone")"
            ),
            GateCheck(
                name: "no audio left on disk",
                ok: left.isEmpty,
                detail: left.isEmpty ? "capture directory has no audio" : "left: \(left.joined(separator: ", "))"
            ),
        ]
    }

    private func touch(_ token: String) -> @Sendable () async -> Void {
        let client = client
        return { _ = try? await client.request("POST", path: "/api/auth/session/touch", idToken: token) }
    }
}

#endif
