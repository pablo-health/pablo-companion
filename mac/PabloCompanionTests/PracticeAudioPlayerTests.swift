import Foundation
@testable import Pablo
import Testing

struct PracticeAudioPlayerTests {
    private func pcm(_ values: [Int16]) -> Data {
        var data = Data()
        for value in values {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    @Test func convertsInt16LittleEndianToNormalizedFloat() {
        let samples = PracticeAudioPlayer.floatSamples(fromInt16LE: pcm([0, Int16.max, -Int16.max, 16384]))
        #expect(samples.count == 4)
        #expect(samples[0] == 0)
        #expect(samples[1] == 1)
        #expect(samples[2] == -1)
        #expect(abs(samples[3] - 0.5) < 0.001)
    }

    @Test func ignoresTrailingOddByte() {
        var data = pcm([100])
        data.append(0x7F)
        #expect(PracticeAudioPlayer.floatSamples(fromInt16LE: data).count == 1)
    }

    @Test func emptyOrSingleByteInputYieldsNoSamples() {
        #expect(PracticeAudioPlayer.floatSamples(fromInt16LE: Data()).isEmpty)
        #expect(PracticeAudioPlayer.floatSamples(fromInt16LE: Data([0x01])).isEmpty)
    }

    @Test func rmsOfFullScaleSquareWaveIsOne() {
        #expect(PracticeAudioPlayer.rms([1, -1, 1, -1]) == 1)
        #expect(PracticeAudioPlayer.rms([]) == 0)
    }

    /// Building the player must not touch the audio graph: it runs at app launch.
    @Test func initDoesNotThrowOrConnect() {
        let player = PracticeAudioPlayer()
        player.enqueue(pcm([1, 2, 3]))
        player.stop()
    }
}
