using System.Net;

namespace PabloCompanion.Core;

/// <summary>
/// Wraps a request body and reports every write, so a long upload can be judged
/// by whether it is still moving rather than by how long it has taken.
///
/// The storage PUT has no overall timeout (a 50-minute session on a home uplink
/// can legitimately take longer than any fixed deadline); the caller resets a
/// stall deadline from <c>onProgress</c> instead. The wrapper adds no headers of
/// its own and reports the inner body's length, so what goes on the wire is
/// exactly the inner body.
/// </summary>
internal sealed class ProgressGuardedContent : HttpContent
{
    private readonly HttpContent _inner;
    private readonly Action _onProgress;

    internal ProgressGuardedContent(HttpContent inner, Action onProgress)
    {
        _inner = inner;
        _onProgress = onProgress;
    }

    protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context) =>
        SerializeToStreamAsync(stream, context, CancellationToken.None);

    protected override async Task SerializeToStreamAsync(
        Stream stream, TransportContext? context, CancellationToken cancellationToken)
    {
        await using var reporting = new ReportingStream(stream, _onProgress);
        await _inner.CopyToAsync(reporting, cancellationToken);
    }

    protected override bool TryComputeLength(out long length)
    {
        if (_inner.Headers.ContentLength is { } known)
        {
            length = known;
            return true;
        }
        length = 0;
        return false;
    }

    /// <summary>Write-only pass-through that calls back after each write. Does not own the target.</summary>
    private sealed class ReportingStream(Stream target, Action onProgress) : Stream
    {
        public override bool CanRead => false;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => throw new NotSupportedException();
        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }

        public override void Write(byte[] buffer, int offset, int count)
        {
            target.Write(buffer, offset, count);
            onProgress();
        }

        public override async ValueTask WriteAsync(
            ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default)
        {
            await target.WriteAsync(buffer, cancellationToken);
            onProgress();
        }

        public override Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
            WriteAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();

        public override void Flush() => target.Flush();
        public override Task FlushAsync(CancellationToken cancellationToken) => target.FlushAsync(cancellationToken);
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
    }
}
