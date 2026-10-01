import Foundation
@testable import Pablo
import Testing

struct AudioCheckEvaluatorTests {
    private static let voice: Float = 0.05
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
        Self.feed(&evaluator, phase: .yourTurn, from: 5, seconds: 2, mic: Self.voice, system: 0)

        #expect(evaluator.heardComputer)
        #expect(evaluator.heardYou)
        #expect(evaluator.passed)
    }

    @Test func aSilentSystemTapFailsTheComputerStep() {
        // The macOS 26 failure the check exists to catch.
        var evaluator = AudioCheckEvaluator()
        Self.feed(&evaluator, phase: .greeting, from: 0, seconds: 5, mic: Self.voice, system: 0)
        Self.feed(&evaluator, phase: .yourTurn, from: 5, seconds: 2, mic: Self.voice, system: 0)

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

    @Test func aClickIsNotAHello() {
        var evaluator = AudioCheckEvaluator()
        Self.feed(&evaluator, phase: .yourTurn, from: 0, seconds: 0.2, mic: Self.voice, system: 0)

        #expect(!evaluator.heardYou)
    }

    @Test func soundOnTheSystemDuringYourTurnIsIgnored() {
        var evaluator = AudioCheckEvaluator()
        Self.feed(&evaluator, phase: .yourTurn, from: 0, seconds: 3, mic: 0, system: Self.voice)

        #expect(!evaluator.heardComputer)
    }
}
