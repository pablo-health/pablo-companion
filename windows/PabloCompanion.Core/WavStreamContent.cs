using System.Net;

namespace PabloCompanion.Core;

/// <summary>
/// Sends a headerless PCM file as a WAV: an accurate 44-byte header followed by
/// the file's bytes, streamed straight from disk.
///
/// Streaming rather than building one big <c>byte[]</c> is the point. A 50-minute
/// session's sidecars run to hundreds of megabytes at 48 kHz, and buffering both
/// channels just to prefix 44 bytes would put that much on the heap of a desktop
/// app that is also recording.
/// </summary>
internal sealed class WavStreamContent : HttpContent
{
    private readonly string _path;
    private readonly byte[] _header;
    private readonly long _dataByteCount;

    /// <param name="path">Headerless little-endian PCM to send.</param>
    /// <param name="sampleRate">Frames per second the PCM was captured at.</param>
    /// <param name="channels">1 for the mono mic sidecar, 2 for the stereo system sidecar.</param>
    internal WavStreamContent(string path, int sampleRate, int channels)
    {
        _path = path;
        // The header must declare the exact payload length, so it's fixed here and
        // the copy below is bounded to match. A sidecar is closed before upload, so
        // this can't race the writer.
        _dataByteCount = new FileInfo(path).Length;
        _header = WAVEncoder.BuildHeader(_dataByteCount, sampleRate, channels);
    }

    protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context)
    {
        await stream.WriteAsync(_header);

        using var file = File.OpenRead(_path);
        // Bounded to the length the header promises: were the file to have grown
        // since construction, copying it whole would contradict Content-Length and
        // desync the multipart body.
        await CopyExactlyAsync(file, stream, _dataByteCount);
    }

    protected override bool TryComputeLength(out long length)
    {
        length = _header.Length + _dataByteCount;
        return true;
    }

    private static async Task CopyExactlyAsync(Stream source, Stream destination, long count)
    {
        var buffer = new byte[81920];
        long remaining = count;
        while (remaining > 0)
        {
            var wanted = (int)Math.Min(buffer.Length, remaining);
            var read = await source.ReadAsync(buffer.AsMemory(0, wanted));
            if (read == 0) break; // truncated under us; send what exists
            await destination.WriteAsync(buffer.AsMemory(0, read));
            remaining -= read;
        }

        // Pad a short read so the body still matches the promised Content-Length.
        // Silence at the tail beats a desynced multipart stream.
        if (remaining > 0)
        {
            var padding = new byte[Math.Min(remaining, buffer.Length)];
            while (remaining > 0)
            {
                var chunk = (int)Math.Min(padding.Length, remaining);
                await destination.WriteAsync(padding.AsMemory(0, chunk));
                remaining -= chunk;
            }
        }
    }
}
