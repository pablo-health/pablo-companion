@testable import Pablo
import Testing

struct LevelMeterTests {
    @Test func silenceReadsEmpty() {
        #expect(LevelMeter.displayFraction(forRMS: 0) == 0)
        #expect(LevelMeter.displayFraction(forRMS: 0.000_1) == 0) // −80 dBFS, below the floor
    }

    @Test func fullScaleReadsFull() {
        #expect(LevelMeter.displayFraction(forRMS: 1) == 1)
        #expect(LevelMeter.displayFraction(forRMS: 1.5) == 1)
    }

    @Test func normalSpeechFillsAboutHalfTheBar() {
        // Regression: drawn linearly, speech-level RMS (~0.03) filled 3% of the
        // bar and the meters looked dead mid-session. −30 dBFS is mid-scale.
        let fraction = LevelMeter.displayFraction(forRMS: 0.031_6)
        #expect(abs(fraction - 0.5) < 0.01)
    }

    @Test func aQuietFarEndVoiceStillRegisters() {
        // ~−45 dBFS: a soft remote speaker should still visibly move the bar.
        #expect(LevelMeter.displayFraction(forRMS: 0.005_6) > 0.2)
    }

    @Test func louderIsAlwaysHigher() {
        let levels: [Float] = [0.001, 0.01, 0.05, 0.1, 0.5, 1]
        let fractions = levels.map(LevelMeter.displayFraction(forRMS:))
        #expect(fractions == fractions.sorted())
        #expect(Set(fractions).count == fractions.count)
    }
}
