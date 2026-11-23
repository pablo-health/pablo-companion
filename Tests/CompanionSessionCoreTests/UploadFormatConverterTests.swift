@testable import CompanionSessionCore
import Foundation
import Testing

/// The converter streams a recording chunk by chunk so memory stays flat however
/// long the session ran. That is only safe if the chunk boundaries are invisible:
/// the output must be the same as converting the whole file at once.
@Suite("Upload format conversion")
struct UploadFormatConverterTests {
    private static func pcm(_ samples: [Int16]) -> Data {
        samples.map(\.littleEndian).withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func samples(_ data: Data) -> [Int16] {
        data.withUnsafeBytes { raw in
            (0 ..< raw.count / 2).map {
                Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))
            }
        }
    }

    /// Converts `input`, fed `chunkBytes` at a time.
    private static func convert(
        _ input: Data, from rate: Double, channels: Int, chunkBytes: Int
    ) -> [Int16] {
        var converter = UploadFormatConverter(inputRate: rate, inputChannels: channels, outputRate: 16000)
        var output = Data()
        var offset = 0
        while offset < input.count {
            let end = min(offset + chunkBytes, input.count)
            output.append(converter.process(input.subdata(in: offset ..< end)))
            offset = end
        }
        output.append(converter.finish())
        return samples(output)
    }

    /// A deterministic, speech-like waveform.
    private static func signal(frames: Int, channels: Int) -> [Int16] {
        (0 ..< frames * channels).map { index in
            let frame = Double(index / channels)
            return Int16(8000 * sin(frame / 7) + 3000 * sin(frame / 31) + Double(index % channels) * 500)
        }
    }

    @Test(arguments: [(48000.0, 2), (48000.0, 1), (44100.0, 2), (24000.0, 1), (8000.0, 1)])
    func chunkBoundariesDoNotChangeTheOutput(rate: Double, channels: Int) {
        let input = Self.pcm(Self.signal(frames: 9001, channels: channels))
        let whole = Self.convert(input, from: rate, channels: channels, chunkBytes: input.count)

        // Odd sizes split frames, and even samples, across chunks.
        for chunkBytes in [1, 3, 7, 1000, 4097] {
            #expect(Self.convert(input, from: rate, channels: channels, chunkBytes: chunkBytes) == whole)
        }
        #expect(whole.count == Int((9001 * 16000 / rate).rounded()))
    }

    @Test func stereoIsAveragedToMono() {
        let input = Self.pcm([100, 300, -200, 200])
        #expect(Self.convert(input, from: 16000, channels: 2, chunkBytes: 1024) == [200, 0])
    }

    @Test func fullScaleStereoDoesNotOverflow() {
        let input = Self.pcm([.max, .max, .min, .min])
        #expect(Self.convert(input, from: 16000, channels: 2, chunkBytes: 1024) == [.max, .min])
    }

    @Test func theUploadRateIsCopiedSampleForSample() {
        let mono = Self.signal(frames: 500, channels: 1)
        #expect(Self.convert(Self.pcm(mono), from: 16000, channels: 1, chunkBytes: 333) == mono)
    }

    @Test func emptyInputGivesEmptyOutput() {
        #expect(Self.convert(Data(), from: 48000, channels: 2, chunkBytes: 1024).isEmpty)
    }
}
