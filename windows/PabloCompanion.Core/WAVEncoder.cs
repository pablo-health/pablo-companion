using System.Buffers.Binary;
using System.Text;

namespace PabloCompanion.Core;

/// <summary>
/// Builds the canonical 44-byte RIFF/WAVE header that makes uploaded PCM
/// self-describing.
///
/// The companion captures headerless PCM sidecars (mic = mono, system = stereo).
/// Uploading them raw under an <c>audio/wav</c> mime forces the backend to
/// <i>guess</i> the format — and its guess (always stereo) silently corrupts the
/// mono mic channel: frames halve and the waveform mangles, so the therapist
/// audio transcribes to nothing. Prepending an accurate header removes the guess
/// entirely; the backend passes any <c>RIFF</c> payload straight through.
///
/// The C# mirror of the macOS <c>WAVEncoder</c> in <c>CompanionSessionCore</c> —
/// both platforms must produce byte-identical headers, so change them together.
/// </summary>
public static class WAVEncoder
{
    /// <summary>Size of the canonical PCM header this encoder emits.</summary>
    public const int HeaderSize = 44;

    /// <summary>
    /// Builds a 44-byte header describing <paramref name="dataByteCount"/> bytes of
    /// little-endian PCM. Split from <see cref="Wrap"/> so a caller can stream the
    /// payload: an hour of 48 kHz audio is hundreds of megabytes, which shouldn't
    /// have to sit in memory just to be prefixed.
    /// </summary>
    /// <param name="dataByteCount">Byte length of the PCM that will follow the header.</param>
    /// <param name="sampleRate">Frames per second, e.g. 48000.</param>
    /// <param name="channels">1 for the mono mic, 2 for stereo system audio.</param>
    /// <param name="bitsPerSample">Bits per sample; the capture path emits 16.</param>
    public static byte[] BuildHeader(long dataByteCount, int sampleRate, int channels, int bitsPerSample = 16)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(dataByteCount);
        ArgumentOutOfRangeException.ThrowIfLessThan(sampleRate, 1);
        ArgumentOutOfRangeException.ThrowIfLessThan(channels, 1);
        ArgumentOutOfRangeException.ThrowIfLessThan(bitsPerSample, 1);

        // RIFF sizes are unsigned 32-bit; past 4 GiB the format simply can't
        // describe the payload, and silently truncating would corrupt it.
        var chunkSize = 36 + dataByteCount;
        ArgumentOutOfRangeException.ThrowIfGreaterThan(chunkSize, uint.MaxValue, nameof(dataByteCount));

        var byteRate = sampleRate * channels * bitsPerSample / 8;
        var blockAlign = channels * bitsPerSample / 8;

        var header = new byte[HeaderSize];
        var span = header.AsSpan();

        WriteAscii(span[..4], "RIFF");
        BinaryPrimitives.WriteUInt32LittleEndian(span.Slice(4, 4), (uint)chunkSize);
        WriteAscii(span.Slice(8, 4), "WAVE");
        WriteAscii(span.Slice(12, 4), "fmt ");
        BinaryPrimitives.WriteUInt32LittleEndian(span.Slice(16, 4), 16); // PCM fmt chunk size
        BinaryPrimitives.WriteUInt16LittleEndian(span.Slice(20, 2), 1);  // audio format = PCM
        BinaryPrimitives.WriteUInt16LittleEndian(span.Slice(22, 2), (ushort)channels);
        BinaryPrimitives.WriteUInt32LittleEndian(span.Slice(24, 4), (uint)sampleRate);
        BinaryPrimitives.WriteUInt32LittleEndian(span.Slice(28, 4), (uint)byteRate);
        BinaryPrimitives.WriteUInt16LittleEndian(span.Slice(32, 2), (ushort)blockAlign);
        BinaryPrimitives.WriteUInt16LittleEndian(span.Slice(34, 2), (ushort)bitsPerSample);
        WriteAscii(span.Slice(36, 4), "data");
        BinaryPrimitives.WriteUInt32LittleEndian(span.Slice(40, 4), (uint)dataByteCount);

        return header;
    }

    /// <summary>
    /// Prepends a WAV header to <paramref name="pcm"/>, returning the complete file
    /// bytes. Convenient for small payloads and tests; prefer
    /// <see cref="BuildHeader"/> plus a stream copy for real recordings.
    /// </summary>
    public static byte[] Wrap(byte[] pcm, int sampleRate, int channels, int bitsPerSample = 16)
    {
        ArgumentNullException.ThrowIfNull(pcm);

        var header = BuildHeader(pcm.Length, sampleRate, channels, bitsPerSample);
        var output = new byte[header.Length + pcm.Length];
        header.CopyTo(output, 0);
        pcm.CopyTo(output, header.Length);
        return output;
    }

    /// <summary>
    /// Whether these bytes already begin a RIFF container, in which case they are
    /// self-describing and must be uploaded untouched rather than double-wrapped.
    /// </summary>
    public static bool IsRiff(ReadOnlySpan<byte> data) =>
        data.Length >= 4 && data[0] == (byte)'R' && data[1] == (byte)'I'
                         && data[2] == (byte)'F' && data[3] == (byte)'F';

    private static void WriteAscii(Span<byte> destination, string value) =>
        Encoding.ASCII.GetBytes(value, destination);
}
