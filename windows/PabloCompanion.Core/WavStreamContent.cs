using System.Net;

namespace PabloCompanion.Core;

/// <summary>
/// Sends a headerless PCM file as a WAV in the upload format: an accurate
/// 44-byte header followed by the file's audio converted to
/// <see cref="AudioUploadClient.UploadSampleRate"/> mono, streamed straight from
/// disk through <see cref="UploadFormatConverter"/>.
///
/// Streaming rather than building one big <c>byte[]</c> is the point. A 50-minute
/// session's sidecars run to hundreds of megabytes at 48 kHz, and buffering both
/// channels just to convert them would put that much on the heap of a desktop
/// app that is also recording. The sidecar on disk is never rewritten.
/// </summary>
internal sealed class WavStreamContent : HttpContent
{
    private readonly string _path;
    private readonly int _sampleRate;
    private readonly int _channels;
    private readonly byte[] _header;
    private readonly long _inputByteCount;
    private readonly long _outputByteCount;

    /// <param name="path">Headerless little-endian PCM to send.</param>
    /// <param name="sampleRate">Frames per second the PCM was captured at.</param>
    /// <param name="channels">1 for the mono mic sidecar, 2 for the stereo system sidecar.</param>
    internal WavStreamContent(string path, int sampleRate, int channels)
    {
        _path = path;
        _sampleRate = sampleRate;
        _channels = channels;
        // The header must declare the exact payload length, so it's fixed here and
        // the copy below is bounded to match. A sidecar is closed before upload, so
        // this can't race the writer. Whole frames only: a trailing partial frame
        // is not audio and the converter drops it.
        var frameBytes = 2 * channels;
        _inputByteCount = new FileInfo(path).Length / frameBytes * frameBytes;
        _outputByteCount = UploadFormatConverter.OutputByteCount(
            _inputByteCount, sampleRate, channels, AudioUploadClient.UploadSampleRate);
        _header = WAVEncoder.BuildHeader(
            _outputByteCount, AudioUploadClient.UploadSampleRate, AudioUploadClient.UploadChannels);
    }

    protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context)
    {
        await stream.WriteAsync(_header);

        var converter = new UploadFormatConverter(_sampleRate, _channels, AudioUploadClient.UploadSampleRate);
        using var file = File.OpenRead(_path);
        // Bounded to the length the header was computed from: were the file to
        // have grown since construction, converting it whole would contradict
        // Content-Length.
        var buffer = new byte[81920];
        long remaining = _inputByteCount;
        long written = 0;
        while (remaining > 0)
        {
            var wanted = (int)Math.Min(buffer.Length, remaining);
            var read = await file.ReadAsync(buffer.AsMemory(0, wanted));
            if (read == 0) break; // truncated under us; send what exists
            var converted = converter.Process(buffer.AsSpan(0, read));
            await stream.WriteAsync(converted);
            written += converted.Length;
            remaining -= read;
        }
        var tail = converter.Finish();
        await stream.WriteAsync(tail);
        written += tail.Length;

        // Pad a short read so the body still matches the promised Content-Length.
        // Silence at the tail beats a body that disagrees with its header.
        await PadAsync(stream, _outputByteCount - written);
    }

    protected override bool TryComputeLength(out long length)
    {
        length = _header.Length + _outputByteCount;
        return true;
    }

    /// <summary>Writes <paramref name="count"/> zero bytes (nothing when it is not positive).</summary>
    internal static async Task PadAsync(Stream destination, long count)
    {
        if (count <= 0) return;
        var padding = new byte[Math.Min(count, 81920)];
        while (count > 0)
        {
            var chunk = (int)Math.Min(padding.Length, count);
            await destination.WriteAsync(padding.AsMemory(0, chunk));
            count -= chunk;
        }
    }
}
