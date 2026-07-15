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
        var out = header(
            dataByteCount: pcm.count,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample
        )
        out.append(pcm)
        return out
    }

    /// The 44-byte canonical RIFF/WAVE header for a `data` chunk of exactly
    /// `dataByteCount` bytes.
    ///
    /// Split out from ``wrap(pcm:sampleRate:channels:bitsPerSample:)`` so a
    /// large PCM sidecar can be turned into a WAV on disk without ever holding
    /// the samples in memory: write this header, then stream the PCM bytes in
    /// after it (see the signed-URL upload path, which must not buffer a
    /// multi-hundred-MB session).
    public static func header(
        dataByteCount: Int,
        sampleRate: Int,
        channels: Int,
        bitsPerSample: Int = 16
    ) -> Data {
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = UInt32(dataByteCount)
        let chunkSize = 36 + dataSize

        var header = Data(capacity: 44)
        header.append(contentsOf: Array("RIFF".utf8))
        appendUInt32LE(chunkSize, to: &header)
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        appendUInt32LE(16, to: &header) // PCM fmt chunk size
        appendUInt16LE(1, to: &header) // audio format = PCM
        appendUInt16LE(UInt16(channels), to: &header)
        appendUInt32LE(UInt32(sampleRate), to: &header)
        appendUInt32LE(UInt32(byteRate), to: &header)
        appendUInt16LE(UInt16(blockAlign), to: &header)
        appendUInt16LE(UInt16(bitsPerSample), to: &header)
        header.append(contentsOf: Array("data".utf8))
        appendUInt32LE(dataSize, to: &header)
        return header
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}
