import Foundation

/// Streams interleaved signed 16-bit little-endian PCM into mono at another
/// rate, one chunk at a time.
///
/// Channels are averaged: each sidecar carries one side of the conversation, so
/// a stereo client channel is a stereo image of the same voices, not two people.
/// The rate is changed by linear interpolation — speech for transcription, not
/// music. State carries across chunks, so the output is identical however the
/// input is split, and memory stays at one chunk however long the recording is.
struct UploadFormatConverter {
    private let channels: Int
    /// Input frames per output frame.
    private let step: Double
    private let outputPerInput: Double

    /// Mono input frames not yet fully consumed; `window[0]` is input frame `base`.
    private var window: [Int16] = []
    private var base = 0
    /// Bytes of a trailing frame split across chunks.
    private var pending = Data()
    private var inputFrames = 0
    private var outputFrames = 0

    init(inputRate: Double, inputChannels: Int, outputRate: Double) {
        precondition(inputRate > 0 && outputRate > 0 && inputChannels > 0)
        channels = inputChannels
        step = inputRate / outputRate
        outputPerInput = outputRate / inputRate
    }

    /// Converts the next chunk of input; returns the mono output it completes.
    mutating func process(_ chunk: Data) -> Data {
        var bytes = pending
        bytes.append(chunk)
        let frameBytes = 2 * channels
        let whole = bytes.count / frameBytes * frameBytes
        pending = Data(bytes.suffix(from: bytes.startIndex + whole))
        appendMono(of: bytes.prefix(whole))
        return emit(final: false)
    }

    /// Flushes the output the last frames of input still owe.
    mutating func finish() -> Data {
        emit(final: true)
    }

    private mutating func appendMono(of bytes: Data) {
        let frames = bytes.count / (2 * channels)
        bytes.withUnsafeBytes { raw in
            window.reserveCapacity(window.count + frames)
            for frame in 0 ..< frames {
                var sum: Int32 = 0
                for channel in 0 ..< channels {
                    let offset = (frame * channels + channel) * 2
                    sum += Int32(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self)))
                }
                window.append(Int16(sum / Int32(channels)))
            }
        }
        inputFrames += frames
    }

    private mutating func emit(final: Bool) -> Data {
        var output: [Int16] = []
        let last = base + window.count - 1
        // Output length matches a whole-file resample: rounded, decided at the end.
        let total = final ? Int((Double(inputFrames) * outputPerInput).rounded()) : Int.max
        while outputFrames < total, last >= base {
            let position = Double(outputFrames) * step
            var lower = Int(position)
            if lower > last {
                guard final else { break }
                lower = last
            }
            let upper = lower + 1
            let from = Double(window[lower - base])
            let to: Double
            if upper <= last {
                to = Double(window[upper - base])
            } else if final {
                to = from
            } else {
                break // the next chunk holds the frame this one interpolates toward
            }
            let fraction = min(position - Double(lower), 1)
            output.append(Int16((from + (to - from) * fraction).rounded()))
            outputFrames += 1
        }
        // Forget input no later output frame can reach.
        let keepFrom = min(Int(Double(outputFrames) * step), last + 1)
        if keepFrom > base {
            window.removeFirst(keepFrom - base)
            base = keepFrom
        }
        return output.map(\.littleEndian).withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
