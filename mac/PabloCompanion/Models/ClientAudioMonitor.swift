import Foundation

/// Watches live capture levels and decides whether the client's side of the
/// call is reaching the recording.
///
/// The old "System audio" indicator only said whether a system-audio source
/// existed when recording started. When macOS hands over a tap that delivers
/// silence — the System Audio Recording permission missing on macOS 26 — it
/// kept saying "System audio" while a whole session recorded a one-sided
/// conversation. This looks at what actually arrives.
///
/// A pure value type fed `(mic, system, time)` samples, so the thresholds are
/// unit-tested and the first-use audio check can share the same judgement.
struct ClientAudioMonitor: Equatable {
    enum Status: Equatable {
        /// Too early to tell — nobody has said enough yet.
        case listening
        /// Client audio has been heard recently.
        case hearingClient
        /// The therapist is talking but nothing is arriving from the call.
        case noClientAudio
    }

    enum Threshold {
        /// Mic level that counts as the therapist speaking.
        static let speechDecibels: Float = -45
        /// System level that counts as hearing the call. Below speech: a
        /// remote voice through a call app is often quiet.
        static let clientDecibels: Float = -55
        /// Therapist speech needed before an absent client is a problem.
        static let speechBeforeWarning: TimeInterval = 5
        /// Never warn sooner than this: the client may still be in the
        /// waiting room, and an empty call outputs real digital silence.
        static let earliestWarning: TimeInterval = 45
        /// After the client has been heard, this much silence from the call —
        /// while the therapist keeps talking — means it was lost.
        static let lostClientAfter: TimeInterval = 120
        static let speechBeforeLostWarning: TimeInterval = 20
        /// Gaps longer than this between samples (sleep, a stalled callback)
        /// count as this much, so one late sample can't add a minute of speech.
        static let maxSampleGap: TimeInterval = 1
    }

    private(set) var status: Status = .listening
    private var startedAt: Date?
    private var lastSampleAt: Date?
    private var lastClientHeardAt: Date?
    /// Therapist speech since the client was last heard (or since start).
    private var speechSinceClient: TimeInterval = 0

    /// Feed one level update (linear RMS, 0–1, as AudioCaptureKit reports).
    mutating func record(micRMS: Float, systemRMS: Float, at now: Date) {
        let start = startedAt ?? now
        startedAt = start
        let gap = lastSampleAt.map { min(max(now.timeIntervalSince($0), 0), Threshold.maxSampleGap) } ?? 0
        lastSampleAt = now

        if Self.decibels(systemRMS) >= Threshold.clientDecibels {
            lastClientHeardAt = now
            speechSinceClient = 0
            status = .hearingClient
            return
        }
        if Self.decibels(micRMS) >= Threshold.speechDecibels {
            speechSinceClient += gap
        }

        if let heard = lastClientHeardAt {
            let lost = now.timeIntervalSince(heard) >= Threshold.lostClientAfter
                && speechSinceClient >= Threshold.speechBeforeLostWarning
            status = lost ? .noClientAudio : .hearingClient
        } else {
            let warn = now.timeIntervalSince(start) >= Threshold.earliestWarning
                && speechSinceClient >= Threshold.speechBeforeWarning
            status = warn ? .noClientAudio : .listening
        }
    }

    /// Start over — a new recording, or resuming from pause.
    mutating func reset() {
        self = Self()
    }

    static func decibels(_ rms: Float) -> Float {
        rms > 0 ? 20 * log10(min(rms, 1)) : -.infinity
    }
}
