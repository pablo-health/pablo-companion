using System.Buffers.Binary;
using System.Net;

namespace PabloCompanion.Core;

/// <summary>
/// Sends an encrypted capture sidecar as the plaintext audio it holds, decrypting
/// chunk by chunk straight into the request stream.
///
/// The sidecar format is a run of length-prefixed AES-GCM chunks:
/// <c>[4-byte LE length][12-byte nonce | ciphertext | 16-byte tag]</c>. GCM is a
/// stream mode, so each chunk's plaintext is exactly <c>length - 28</c> bytes, and
/// the body's size is known by walking the prefixes without decrypting anything.
/// That matters three ways for a signed direct-to-storage PUT:
/// <list type="bullet">
/// <item>No plaintext ever touches disk, and memory stays at about one chunk
/// however long the session ran. Decrypting to a temp file first would leave
/// session audio in <c>%TEMP%</c>, and done the obvious way would read the whole
/// sidecar into memory.</item>
/// <item>The request carries an exact <c>Content-Length</c>, which storage checks
/// against the signed <c>x-goog-content-length-range</c>.</item>
/// <item>The exact size is what the init response's <c>existing_bytes</c> is
/// compared against to skip a channel an earlier attempt already stored.</item>
/// </list>
///
/// Format-agnostic, like the macOS uploader: if the decrypted audio is already a
/// self-describing container (a RIFF WAV or an ADTS AAC stream) it is sent
/// through unchanged; only headerless PCM gets the 44-byte WAV header.
///
/// A trailing chunk cut short (the writer stopped mid-chunk) is left out of both
/// the length and the body, matching how the sidecar has always been read. A
/// chunk that fails authentication fails the upload; it is never sent as audio.
/// </summary>
public sealed class EncryptedPcmWavContent : HttpContent
{
    /// <summary>AES-GCM nonce (12) plus tag (16): what each chunk carries beyond its plaintext.</summary>
    public const int ChunkOverhead = 12 + 16;

    /// <summary>
    /// Ceiling on one chunk's declared length. Capture writes one audio buffer per
    /// chunk (kilobytes); a prefix anywhere near this is corrupt, and trusting it
    /// would allocate whatever the corruption says.
    /// </summary>
    private const int MaxChunkLength = 16 * 1024 * 1024;

    private readonly string _path;
    private readonly Func<byte[], byte[]> _decryptChunk;
    private readonly int _chunkCount;
    private readonly byte[] _header;

    /// <summary>Plaintext bytes the sidecar decrypts to, excluding any WAV header.</summary>
    public long PlaintextLength { get; }

    /// <summary>Whether the decrypted audio is already self-describing and is sent unwrapped.</summary>
    public bool IsPassthrough { get; }

    /// <param name="path">Encrypted sidecar (<c>.enc.pcm</c>).</param>
    /// <param name="sampleRate">Frames per second the audio was captured at; stamped into the WAV header.</param>
    /// <param name="channels">1 for the mono mic sidecar, 2 for the stereo system sidecar.</param>
    /// <param name="decryptChunk">Decrypts one combined <c>nonce|ciphertext|tag</c> chunk to its plaintext.</param>
    public EncryptedPcmWavContent(
        string path, int sampleRate, int channels, Func<byte[], byte[]> decryptChunk)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        ArgumentNullException.ThrowIfNull(decryptChunk);

        _path = path;
        _decryptChunk = decryptChunk;

        // The sidecar is closed before upload, so this walk can't race the writer.
        using var file = OpenRead(path);
        (_chunkCount, var plaintextLength) = Scan(file);
        PlaintextLength = plaintextLength;

        file.Position = 0;
        IsPassthrough = AudioFormat.IsSelfDescribing(ReadPlaintextPrefix(file, _chunkCount, wanted: 4));
        _header = IsPassthrough
            ? []
            : WAVEncoder.BuildHeader(plaintextLength, sampleRate, channels);
    }

    protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context) =>
        SerializeToStreamAsync(stream, context, CancellationToken.None);

    protected override async Task SerializeToStreamAsync(
        Stream stream, TransportContext? context, CancellationToken cancellationToken)
    {
        if (_header.Length > 0)
            await stream.WriteAsync(_header, cancellationToken);

        using var file = OpenRead(_path);
        var prefix = new byte[4];
        byte[]? chunk = null;

        // Bounded to the chunk count the length was computed from, so the body can
        // never disagree with Content-Length.
        for (var i = 0; i < _chunkCount; i++)
        {
            await file.ReadExactlyAsync(prefix, cancellationToken);
            var length = (int)BinaryPrimitives.ReadUInt32LittleEndian(prefix);

            // Chunks are almost all one size; reuse the buffer when they are.
            if (chunk is null || chunk.Length != length) chunk = new byte[length];
            await file.ReadExactlyAsync(chunk, cancellationToken);

            await stream.WriteAsync(DecryptChecked(chunk), cancellationToken);
        }
    }

    protected override bool TryComputeLength(out long length)
    {
        length = _header.Length + PlaintextLength;
        return true;
    }

    /// <summary>
    /// Walks the length prefixes, counting complete chunks and summing their
    /// plaintext. Stops at a trailing chunk cut short.
    /// </summary>
    private static (int ChunkCount, long PlaintextLength) Scan(FileStream file)
    {
        Span<byte> prefix = stackalloc byte[4];
        var fileLength = file.Length;
        var count = 0;
        long plaintext = 0;

        while (file.Position + 4 <= fileLength)
        {
            file.ReadExactly(prefix);
            var length = BinaryPrimitives.ReadUInt32LittleEndian(prefix);
            if (length < ChunkOverhead || length > MaxChunkLength)
                throw new InvalidDataException("Encrypted recording has a corrupt chunk length.");
            if (file.Position + length > fileLength) break; // truncated tail

            file.Seek(length, SeekOrigin.Current);
            count++;
            plaintext += length - ChunkOverhead;
        }

        return (count, plaintext);
    }

    /// <summary>
    /// Decrypts leading chunks until <paramref name="wanted"/> plaintext bytes are
    /// in hand or the chunks run out — enough to tell PCM from a container.
    /// </summary>
    private byte[] ReadPlaintextPrefix(FileStream file, int chunkCount, int wanted)
    {
        var collected = new List<byte>(wanted);
        Span<byte> prefix = stackalloc byte[4];
        for (var i = 0; i < chunkCount && collected.Count < wanted; i++)
        {
            file.ReadExactly(prefix);
            var chunk = new byte[BinaryPrimitives.ReadUInt32LittleEndian(prefix)];
            file.ReadExactly(chunk);
            var plaintext = DecryptChecked(chunk);
            collected.AddRange(plaintext.AsSpan(0, Math.Min(plaintext.Length, wanted - collected.Count)));
        }
        return [.. collected];
    }

    private byte[] DecryptChecked(byte[] chunk)
    {
        var plaintext = _decryptChunk(chunk);
        // The length was promised from the prefixes before a byte was decrypted; a
        // decryptor that disagrees would desync the body from Content-Length.
        if (plaintext.Length != chunk.Length - ChunkOverhead)
            throw new InvalidDataException("Encrypted recording chunk decrypted to an unexpected length.");
        return plaintext;
    }

    private static FileStream OpenRead(string path) =>
        new(path, FileMode.Open, FileAccess.Read, FileShare.Read, bufferSize: 81920, useAsync: true);
}
