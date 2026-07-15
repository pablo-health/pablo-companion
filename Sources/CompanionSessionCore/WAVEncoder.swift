import Foundation

/// Wraps raw little-endian PCM in a canonical 44-byte RIFF/WAVE header so the
/// uploaded audio is self-describing.
///
/// The companion captures headerless PCM sidecars (mic = mono, system = stereo).
/// Uploading them raw forces the backend to *guess* the format — and its guess
/// (always stereo) silently corrupts the mono mic channel. Prepending an
/// accurate header removes the guess entirely: the backend passes any `RIFF`
/// payload straight through to transcription.
public enum WAVEncoder {
    /// Prepends a WAV header describing `pcm` as `channels`-channel,
    /// `bitsPerSample`-bit, `sampleRate`-Hz little-endian PCM.
    public static func wrap(
        pcm: Data,
        sampleRate: Int,
        channels: Int,
        bitsPerSample: Int = 16
    ) -> Data {
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = UInt32(pcm.count)
        let chunkSize = 36 + dataSize

        var header = Data(capacity: 44)
        header.append(contentsOf: Array("RIFF".utf8))
        header.appendUInt32LE(chunkSize)
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        header.appendUInt32LE(16) // PCM fmt chunk size
        header.appendUInt16LE(1) // audio format = PCM
        header.appendUInt16LE(UInt16(channels))
        header.appendUInt32LE(UInt32(sampleRate))
        header.appendUInt32LE(UInt32(byteRate))
        header.appendUInt16LE(UInt16(blockAlign))
        header.appendUInt16LE(UInt16(bitsPerSample))
        header.append(contentsOf: Array("data".utf8))
        header.appendUInt32LE(dataSize)

        var out = header
        out.append(pcm)
        return out
    }
}

private extension Data {
    mutating func appendUInt32LE(_ value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
