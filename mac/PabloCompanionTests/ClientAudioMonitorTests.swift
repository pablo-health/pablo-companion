import Foundation
@testable import Pablo
import Testing

struct ClientAudioMonitorTests {
    private static let speech: Float = 0.05 // ≈ −26 dBFS
    private static let quietClient: Float = 0.003 // ≈ −50 dBFS
    private static let start = Date(timeIntervalSinceReferenceDate: 0)

    /// Feeds `seconds` of samples at 10 Hz.
    private static func feed(
        _ monitor: inout ClientAudioMonitor,
        from offset: TimeInterval,
        seconds: TimeInterval,
        mic: Float,
        system: Float
    ) {
        var t = offset
        while t < offset + seconds {
            monitor.record(micRMS: mic, systemRMS: system, at: start.addingTimeInterval(t))
            t += 0.1
        }
    }

    @Test func warnsWhenTheTherapistTalksAndNothingArrivesFromTheCall() {
        // The macOS 26 failure: a permission-less tap delivers pure silence for
        // the whole session while the therapist talks normally.
        var monitor = ClientAudioMonitor()
        Self.feed(&monitor, from: 0, seconds: 50, mic: Self.speech, system: 0)

        #expect(monitor.status == .noClientAudio)
    }

    @Test func doesNotWarnBeforeTheClientCouldHaveJoined() {
        var monitor = ClientAudioMonitor()
        Self.feed(&monitor, from: 0, seconds: 40, mic: Self.speech, system: 0)

        #expect(monitor.status == .listening)
    }

    @Test func doesNotWarnWhileTheTherapistIsSilentToo() {
        // Waiting in an empty call: neither side is talking.
        var monitor = ClientAudioMonitor()
        Self.feed(&monitor, from: 0, seconds: 90, mic: 0.000_5, system: 0)

        #expect(monitor.status == .listening)
    }

    @Test func aQuietRemoteVoiceCountsAsHearingTheClient() {
        var monitor = ClientAudioMonitor()
        Self.feed(&monitor, from: 0, seconds: 30, mic: Self.speech, system: 0)
        Self.feed(&monitor, from: 30, seconds: 1, mic: 0, system: Self.quietClient)

        #expect(monitor.status == .hearingClient)
    }

    @Test func theWarningClearsOnceTheClientIsHeard() {
        var monitor = ClientAudioMonitor()
        Self.feed(&monitor, from: 0, seconds: 50, mic: Self.speech, system: 0)
        #expect(monitor.status == .noClientAudio)

        Self.feed(&monitor, from: 50, seconds: 1, mic: 0, system: Self.speech)

        #expect(monitor.status == .hearingClient)
    }

    @Test func warnsAgainIfTheClientIsLostMidSession() {
        // Call audio moved to another output device mid-session.
        var monitor = ClientAudioMonitor()
        Self.feed(&monitor, from: 0, seconds: 10, mic: 0, system: Self.speech)
        Self.feed(&monitor, from: 10, seconds: 130, mic: Self.speech, system: 0)

        #expect(monitor.status == .noClientAudio)
    }

    @Test func aLongListeningPauseIsNotALostClient() {
        // Client heard, then a long stretch where nobody says much.
        var monitor = ClientAudioMonitor()
        Self.feed(&monitor, from: 0, seconds: 10, mic: 0, system: Self.speech)
        Self.feed(&monitor, from: 10, seconds: 150, mic: 0.000_5, system: 0)

        #expect(monitor.status == .hearingClient)
    }

    @Test func aSingleLateSampleCannotAddAMinuteOfSpeech() {
        var monitor = ClientAudioMonitor()
        monitor.record(micRMS: Self.speech, systemRMS: 0, at: Self.start)
        monitor.record(micRMS: Self.speech, systemRMS: 0, at: Self.start.addingTimeInterval(60))

        #expect(monitor.status == .listening)
    }

    @Test func resetStartsOver() {
        var monitor = ClientAudioMonitor()
        Self.feed(&monitor, from: 0, seconds: 50, mic: Self.speech, system: 0)
        monitor.reset()

        #expect(monitor.status == .listening)
        Self.feed(&monitor, from: 100, seconds: 10, mic: Self.speech, system: 0)
        #expect(monitor.status == .listening)
    }
}
