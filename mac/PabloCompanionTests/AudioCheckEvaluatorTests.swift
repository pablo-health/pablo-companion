import Foundation
@testable import Pablo
import Testing

struct AudioCheckEvaluatorTests {
    private static let voice: Float = 0.05 // ≈ −26 dBFS
    private static let quietRoom: Float = 0.001 // ≈ −60 dBFS
    private static let start = Date(timeIntervalSinceReferenceDate: 0)

    private static func feed(
        _ evaluator: inout AudioCheckEvaluator,
        phase: AudioCheckEvaluator.Phase,
        from offset: TimeInterval,
        seconds: TimeInterval,
        mic: Float,
        system: Float
    ) {
        var t = offset
        while t < offset + seconds {
            evaluator.record(micRMS: mic, systemRMS: system, phase: phase, at: start.addingTimeInterval(t))
            t += 0.1
        }
    }

    @Test func passesWhenTheGreetingIsCapturedAndTheTherapistAnswers() {
        var evaluator = AudioCheckEvaluator()
        Self.feed(&evaluator, phase: .greeting, from: 0, seconds: 5, mic: Self.voice, system: Self.voice)
        Self.answerHello(&evaluator, from: 5)

        #expect(evaluator.heardComputer)
        #expect(evaluator.heardYou)
        #expect(evaluator.passed)
    }

    @Test func aSilentSystemTapFailsTheComputerStep() {
        // The macOS 26 failure the check exists to catch.
        var evaluator = AudioCheckEvaluator()
        Self.feed(&evaluator, phase: .greeting, from: 0, seconds: 5, mic: Self.voice, system: 0)
        Self.answerHello(&evaluator, from: 5)

        #expect(!evaluator.heardComputer)
        #expect(evaluator.heardYou)
        #expect(!evaluator.passed)
    }

    @Test func theMicHearingTheGreetingDoesNotCountAsTheTherapist() {
        // The mic picks Pablo up through the speakers; only the therapist's
        // turn counts.
        var evaluator = AudioCheckEvaluator()
        Self.feed(&evaluator, phase: .greeting, from: 0, seconds: 5, mic: Self.voice, system: Self.voice)
        Self.feed(&evaluator, phase: .yourTurn, from: 5, seconds: 8, mic: 0.000_5, system: 0)

        #expect(evaluator.heardComputer)
        #expect(!evaluator.heardYou)
    }

    /// A beat of room quiet, then about a second and a half of speaking.
    private static func answerHello(_ evaluator: inout AudioCheckEvaluator, from offset: TimeInterval) {
        feed(&evaluator, phase: .yourTurn, from: offset, seconds: 0.5, mic: quietRoom, system: 0)
        feed(&evaluator, phase: .yourTurn, from: offset + 0.5, seconds: 1.5, mic: voice, system: 0)
    }

    @Test func aCoughIsNotAHello() {
        var evaluator = AudioCheckEvaluator()
        Self.feed(&evaluator, phase: .yourTurn, from: 0, seconds: 0.5, mic: Self.quietRoom, system: 0)
        Self.feed(&evaluator, phase: .yourTurn, from: 0.5, seconds: 0.4, mic: Self.voice, system: 0)
        Self.feed(&evaluator, phase: .yourTurn, from: 0.9, seconds: 3, mic: Self.quietRoom, system: 0)

        #expect(!evaluator.heardYou)
    }

    @Test func steadyNoiseNeverCountsAsSpeaking() {
        // A loud fan right by the mic: above −45 dBFS, but it is the room's
        // background, not someone talking.
        var evaluator = AudioCheckEvaluator()
        Self.feed(&evaluator, phase: .yourTurn, from: 0, seconds: 8, mic: 0.03, system: 0)

        #expect(!evaluator.heardYou)
    }

    @Test func speakingOverANoisyRoomStillCounts() {
        var evaluator = AudioCheckEvaluator()
        Self.feed(&evaluator, phase: .yourTurn, from: 0, seconds: 0.5, mic: 0.006, system: 0) // ≈ −44 dBFS fan
        Self.feed(&evaluator, phase: .yourTurn, from: 0.5, seconds: 1.5, mic: 0.08, system: 0) // ≈ −22 dBFS voice

        #expect(evaluator.heardYou)
    }

    @Test func speakingStraightAwayCountsOnceThereIsAPause() {
        // No quiet before the first word: the gap between words gives the
        // background, and the speaking after it counts.
        var evaluator = AudioCheckEvaluator()
        Self.feed(&evaluator, phase: .yourTurn, from: 0, seconds: 0.6, mic: Self.voice, system: 0)
        Self.feed(&evaluator, phase: .yourTurn, from: 0.6, seconds: 0.3, mic: Self.quietRoom, system: 0)
        Self.feed(&evaluator, phase: .yourTurn, from: 0.9, seconds: 1.3, mic: Self.voice, system: 0)

        #expect(evaluator.heardYou)
    }

    @Test func soundOnTheSystemDuringYourTurnIsIgnored() {
        var evaluator = AudioCheckEvaluator()
        Self.feed(&evaluator, phase: .yourTurn, from: 0, seconds: 3, mic: 0, system: Self.voice)

        #expect(!evaluator.heardComputer)
    }
}
