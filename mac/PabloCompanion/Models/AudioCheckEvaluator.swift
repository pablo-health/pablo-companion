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

    /// Speaking needed to count as "heard you": longer than a cough, a click
    /// or a door, comfortably shorter than "Hello, Pablo".
    static let speechNeeded: TimeInterval = 1
    /// How far above the room's background speaking has to rise. Steady noise
    /// — a fan, an air conditioner — sits at the background and never counts.
    static let aboveBackgroundDecibels: Float = 10

    private(set) var heardComputer = false
    private(set) var heardYou = false
    private var speech: TimeInterval = 0
    /// Quietest the mic has been during the therapist's turn. Silence before
    /// they start, or the pauses between words, pull it down to the room.
    private var backgroundDecibels: Float?
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
            let level = ClientAudioMonitor.decibels(micRMS)
            let background = min(backgroundDecibels ?? level, level)
            backgroundDecibels = background
            let speaking = level >= ClientAudioMonitor.Threshold.speechDecibels
                && level >= background + Self.aboveBackgroundDecibels
            if speaking {
                speech += gap
                if speech >= Self.speechNeeded { heardYou = true }
            }
        }
    }
}
