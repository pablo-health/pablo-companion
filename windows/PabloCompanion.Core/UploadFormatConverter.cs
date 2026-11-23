using System.Buffers.Binary;

namespace PabloCompanion.Core;

/// <summary>
/// Streams interleaved signed 16-bit little-endian PCM into mono at another
/// rate, one chunk at a time.
///
/// Channels are averaged: each sidecar carries one side of the conversation, so
/// a stereo client channel is a stereo image of the same voices, not two people.
/// The rate is changed by linear interpolation (speech for transcription, not
/// music). State carries across chunks, so the output is identical however the
/// input is split, and memory stays at one chunk however long the recording is.
///
/// The C# mirror of macOS <c>CompanionSessionCore.UploadFormatConverter</c>; the
/// two produce the same bytes for the same input, so change them together.
/// </summary>
internal sealed class UploadFormatConverter
{
    private readonly int _channels;

    /// <summary>Input frames per output frame.</summary>
    private readonly double _step;

    private readonly double _outputPerInput;

    /// <summary>Mono input frames not yet fully consumed; <c>_window[0]</c> is input frame <see cref="_base"/>.</summary>
    private readonly List<short> _window = [];

    private long _base;

    /// <summary>Bytes of a trailing frame split across chunks.</summary>
    private byte[] _pending = [];

    private long _inputFrames;
    private long _outputFrames;

    /// <param name="inputRate">Frames per second of the input.</param>
    /// <param name="inputChannels">Interleaved channels in the input.</param>
    /// <param name="outputRate">Frames per second of the mono output.</param>
    public UploadFormatConverter(int inputRate, int inputChannels, int outputRate)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(inputRate, 1);
        ArgumentOutOfRangeException.ThrowIfLessThan(inputChannels, 1);
        ArgumentOutOfRangeException.ThrowIfLessThan(outputRate, 1);
        _channels = inputChannels;
        _step = inputRate / (double)outputRate;
        _outputPerInput = outputRate / (double)inputRate;
    }

    /// <summary>
    /// Mono output frames a whole input of <paramref name="inputFrames"/> frames
    /// converts to: what <see cref="Finish"/> brings the total to, so a caller can
    /// promise an exact Content-Length before converting a byte.
    /// </summary>
    public static long OutputFrameCount(long inputFrames, int inputRate, int outputRate)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(inputFrames);
        ArgumentOutOfRangeException.ThrowIfLessThan(inputRate, 1);
        ArgumentOutOfRangeException.ThrowIfLessThan(outputRate, 1);
        var outputPerInput = outputRate / (double)inputRate;
        return (long)Math.Round(inputFrames * outputPerInput, MidpointRounding.AwayFromZero);
    }

    /// <summary>
    /// Bytes of mono 16-bit output that <paramref name="inputBytes"/> bytes of
    /// interleaved 16-bit input convert to. A trailing partial frame is dropped,
    /// as the converter drops it.
    /// </summary>
    public static long OutputByteCount(long inputBytes, int inputRate, int inputChannels, int outputRate)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(inputBytes);
        ArgumentOutOfRangeException.ThrowIfLessThan(inputChannels, 1);
        var inputFrames = inputBytes / (2 * inputChannels);
        return OutputFrameCount(inputFrames, inputRate, outputRate) * 2;
    }

    /// <summary>Converts the next chunk of input; returns the mono output it completes.</summary>
    public byte[] Process(ReadOnlySpan<byte> chunk)
    {
        var frameBytes = 2 * _channels;
        byte[] bytes;
        if (_pending.Length == 0)
        {
            bytes = chunk.ToArray();
        }
        else
        {
            bytes = new byte[_pending.Length + chunk.Length];
            _pending.CopyTo(bytes, 0);
            chunk.CopyTo(bytes.AsSpan(_pending.Length));
        }

        var whole = bytes.Length / frameBytes * frameBytes;
        _pending = whole == bytes.Length ? [] : bytes[whole..];
        AppendMono(bytes.AsSpan(0, whole));
        return Emit(final: false);
    }

    /// <summary>Flushes the output the last frames of input still owe.</summary>
    public byte[] Finish() => Emit(final: true);

    private void AppendMono(ReadOnlySpan<byte> bytes)
    {
        var frames = bytes.Length / (2 * _channels);
        _window.EnsureCapacity(_window.Count + frames);
        for (var frame = 0; frame < frames; frame++)
        {
            var sum = 0;
            for (var channel = 0; channel < _channels; channel++)
            {
                var offset = (frame * _channels + channel) * 2;
                sum += BinaryPrimitives.ReadInt16LittleEndian(bytes.Slice(offset, 2));
            }
            _window.Add((short)(sum / _channels));
        }
        _inputFrames += frames;
    }

    private byte[] Emit(bool final)
    {
        var output = new List<short>();
        var last = _base + _window.Count - 1;
        // Output length matches a whole-file resample: rounded, decided at the end.
        var total = final
            ? (long)Math.Round(_inputFrames * _outputPerInput, MidpointRounding.AwayFromZero)
            : long.MaxValue;
        while (_outputFrames < total && last >= _base)
        {
            var position = _outputFrames * _step;
            var lower = (long)position;
            if (lower > last)
            {
                if (!final) break;
                lower = last;
            }
            var upper = lower + 1;
            double from = _window[(int)(lower - _base)];
            double to;
            if (upper <= last)
            {
                to = _window[(int)(upper - _base)];
            }
            else if (final)
            {
                to = from;
            }
            else
            {
                break; // the next chunk holds the frame this one interpolates toward
            }
            var fraction = Math.Min(position - lower, 1);
            output.Add((short)Math.Round(from + (to - from) * fraction, MidpointRounding.AwayFromZero));
            _outputFrames++;
        }

        // Forget input no later output frame can reach.
        var keepFrom = Math.Min((long)(_outputFrames * _step), last + 1);
        if (keepFrom > _base)
        {
            _window.RemoveRange(0, (int)(keepFrom - _base));
            _base = keepFrom;
        }

        var result = new byte[output.Count * 2];
        for (var i = 0; i < output.Count; i++)
            BinaryPrimitives.WriteInt16LittleEndian(result.AsSpan(i * 2, 2), output[i]);
        return result;
    }
}
