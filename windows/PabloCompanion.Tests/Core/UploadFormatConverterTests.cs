using System.Buffers.Binary;
using PabloCompanion.Core;

namespace PabloCompanion.Tests.Core;

/// <summary>
/// The converter streams a recording chunk by chunk so memory stays flat however
/// long the session ran. That is only safe if the chunk boundaries are invisible:
/// the output must be the same as converting the whole file at once, and the
/// length promised before a byte is converted must be the length that comes out.
///
/// The cases mirror the macOS <c>UploadFormatConverterTests</c> and
/// <c>SegmentedUploadTests</c>, so the two platforms are held to the same bytes.
/// </summary>
public class UploadFormatConverterTests
{
    private const int UploadRate = AudioUploadClient.UploadSampleRate;

    private static byte[] Pcm(short[] samples)
    {
        var bytes = new byte[samples.Length * 2];
        for (var i = 0; i < samples.Length; i++)
            BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(i * 2, 2), samples[i]);
        return bytes;
    }

    private static short[] Samples(byte[] data)
    {
        var samples = new short[data.Length / 2];
        for (var i = 0; i < samples.Length; i++)
            samples[i] = BinaryPrimitives.ReadInt16LittleEndian(data.AsSpan(i * 2, 2));
        return samples;
    }

    /// <summary>Converts <paramref name="input"/>, fed <paramref name="chunkBytes"/> at a time.</summary>
    private static short[] Convert(byte[] input, int rate, int channels, int chunkBytes)
    {
        var converter = new UploadFormatConverter(rate, channels, UploadRate);
        var output = new List<byte>();
        for (var offset = 0; offset < input.Length; offset += chunkBytes)
        {
            var end = Math.Min(offset + chunkBytes, input.Length);
            output.AddRange(converter.Process(input.AsSpan(offset, end - offset)));
        }
        output.AddRange(converter.Finish());
        return Samples([.. output]);
    }

    /// <summary>A deterministic, speech-like waveform.</summary>
    private static short[] Signal(int frames, int channels) =>
        Enumerable.Range(0, frames * channels).Select(index =>
        {
            double frame = index / channels;
            return (short)(8000 * Math.Sin(frame / 7) + 3000 * Math.Sin(frame / 31) + index % channels * 500);
        }).ToArray();

    [Theory]
    [InlineData(48000, 2)]
    [InlineData(48000, 1)]
    [InlineData(44100, 2)]
    [InlineData(24000, 1)]
    [InlineData(8000, 1)]
    public void ChunkBoundariesDoNotChangeTheOutput(int rate, int channels)
    {
        var input = Pcm(Signal(frames: 9001, channels));
        var whole = Convert(input, rate, channels, chunkBytes: input.Length);

        // Odd sizes split frames, and even samples, across chunks.
        foreach (var chunkBytes in new[] { 1, 3, 7, 1000, 4097 })
            Assert.Equal(whole, Convert(input, rate, channels, chunkBytes));

        Assert.Equal((int)Math.Round(9001 * 16000.0 / rate, MidpointRounding.AwayFromZero), whole.Length);
    }

    [Theory]
    [InlineData(48000, 2)]
    [InlineData(48000, 1)]
    [InlineData(44100, 2)]
    [InlineData(24000, 1)]
    [InlineData(8000, 1)]
    public void TheLengthPromisedUpFrontIsTheLengthProduced(int rate, int channels)
    {
        // Content-Length is declared from the input size before conversion; a
        // byte off either way and storage rejects the PUT.
        var input = Pcm(Signal(frames: 9001, channels));
        var produced = Convert(input, rate, channels, chunkBytes: 4097).Length * 2;

        Assert.Equal(produced, UploadFormatConverter.OutputByteCount(input.Length, rate, channels, UploadRate));
        Assert.Equal(produced, UploadFormatConverter.OutputFrameCount(9001, rate, UploadRate) * 2);
        // A trailing partial frame is not audio: dropped by both.
        var torn = input.Concat(new byte[1]).ToArray();
        Assert.Equal(produced, Convert(torn, rate, channels, chunkBytes: 1000).Length * 2);
        Assert.Equal(produced, UploadFormatConverter.OutputByteCount(torn.Length, rate, channels, UploadRate));
    }

    [Fact]
    public void StereoIsAveragedToMono()
    {
        var input = Pcm([100, 300, -200, 200]);
        Assert.Equal([200, 0], Convert(input, 16000, channels: 2, chunkBytes: 1024));
    }

    [Fact]
    public void FullScaleStereoDoesNotOverflow()
    {
        var input = Pcm([short.MaxValue, short.MaxValue, short.MinValue, short.MinValue]);
        Assert.Equal([short.MaxValue, short.MinValue], Convert(input, 16000, channels: 2, chunkBytes: 1024));
    }

    [Fact]
    public void TheUploadRateIsCopiedSampleForSample()
    {
        var mono = Signal(frames: 500, channels: 1);
        Assert.Equal(mono, Convert(Pcm(mono), 16000, channels: 1, chunkBytes: 333));
    }

    [Fact]
    public void EmptyInputGivesEmptyOutput() =>
        Assert.Empty(Convert([], 48000, channels: 2, chunkBytes: 1024));

    [Fact]
    public void A48kCaptureKeepsEveryThirdFrame()
    {
        // A 48 kHz capture as RecordingService writes it: mono mic, stereo client.
        Assert.Equal([30, 60], Convert(Pcm([30, 30, 30, 60, 60, 60]), 48000, channels: 1, chunkBytes: 5));
        Assert.Equal(
            [15, 50],
            Convert(Pcm([10, 20, 10, 20, 10, 20, 40, 60, 40, 60, 40, 60]), 48000, channels: 2, chunkBytes: 5));
    }

    [Fact]
    public void AHandsFreeHeadsetAt8kIsInterpolatedUp()
    {
        // Two frames at 8 kHz are four at 16 kHz, interpolated, the last held.
        Assert.Equal([0, 150, 300, 300], Convert(Pcm([0, 300]), 8000, channels: 1, chunkBytes: 1));
    }
}
