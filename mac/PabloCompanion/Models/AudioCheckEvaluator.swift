import Foundation

/// Judges the first-use audio check from live levels. Uses the same thresholds
/// as `ClientAudioMonitor`, so "Pablo heard your computer" here means exactly
/// what "hearing client" means in a session.
struct AudioCheckEvaluator: Equatable {
    enum Phase: Equatable {
        /// Pablo's greeting is playing through the Mac's output.
        case greeting
        /// The therapist has been asked to say hello.
        case yourTurn
    }

    /// Mic speech needed to count as "heard you" — enough to rule out a click.
    static let speechNeeded: TimeInterval = 0.4

    private(set) var heardComputer = false
    private(set) var heardYou = false
    private var speech: TimeInterval = 0
    private var lastSampleAt: Date?

    var passed: Bool {
        heardComputer && heardYou
    }

    mutating func record(micRMS: Float, systemRMS: Float, phase: Phase, at now: Date) {
        let gap = lastSampleAt.map {
            min(max(now.timeIntervalSince($0), 0), ClientAudioMonitor.Threshold.maxSampleGap)
        } ?? 0
        lastSampleAt = now

        switch phase {
        case .greeting:
            // The greeting reaches the system tap exactly as a client's voice
            // would. The mic is ignored here: it hears the speakers too.
            if ClientAudioMonitor.decibels(systemRMS) >= ClientAudioMonitor.Threshold.clientDecibels {
                heardComputer = true
            }
        case .yourTurn:
            if ClientAudioMonitor.decibels(micRMS) >= ClientAudioMonitor.Threshold.speechDecibels {
                speech += gap
                if speech >= Self.speechNeeded { heardYou = true }
            }
        }
    }
}
