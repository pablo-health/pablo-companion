using System.Buffers.Binary;
using System.Text;
using PabloCompanion.Core;

namespace PabloCompanion.Tests.Core;

/// <summary>
/// Pins the WAV header wire format. The backend passes any RIFF payload straight
/// through to transcription and only guesses the format when the header is
/// absent — and its guess (always stereo) corrupts the mono mic channel. So these
/// bytes are load-bearing: a wrong channel count or sample rate here transcribes
/// to nothing, with no error anywhere.
///
/// These must stay byte-identical to the macOS <c>WAVEncoder</c>.
/// </summary>
public class WAVEncoderTests
{
    private static string Ascii(byte[] header, int offset) =>
        Encoding.ASCII.GetString(header, offset, 4);

    [Fact]
    public void Header_HasCanonicalRiffLayout()
    {
        var header = WAVEncoder.BuildHeader(dataByteCount: 1000, sampleRate: 48000, channels: 1);

        Assert.Equal(44, header.Length);
        Assert.Equal("RIFF", Ascii(header, 0));
        Assert.Equal("WAVE", Ascii(header, 8));
        Assert.Equal("fmt ", Ascii(header, 12));
        Assert.Equal("data", Ascii(header, 36));
        Assert.Equal(36u + 1000, BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(4, 4)));
        Assert.Equal(16u, BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(16, 4)));
        Assert.Equal(1, BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(20, 2))); // PCM
        Assert.Equal(1000u, BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(40, 4)));
    }

    [Fact]
    public void MonoHeader_DescribesTherapistAudio()
    {
        var header = WAVEncoder.BuildHeader(dataByteCount: 960, sampleRate: 48000, channels: 1);

        Assert.Equal(1, BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(22, 2)));       // channels
        Assert.Equal(48000u, BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(24, 4)));  // sample rate
        Assert.Equal(96000u, BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(28, 4)));  // byte rate
        Assert.Equal(2, BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(32, 2)));       // block align
        Assert.Equal(16, BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(34, 2)));      // bits
    }

    [Fact]
    public void StereoHeader_DescribesClientAudio()
    {
        var header = WAVEncoder.BuildHeader(dataByteCount: 960, sampleRate: 48000, channels: 2);

        Assert.Equal(2, BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(22, 2)));
        Assert.Equal(192000u, BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(28, 4))); // 48000*2*2
        Assert.Equal(4, BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(32, 2)));
    }

    [Fact]
    public void Wrap_PrependsHeaderAndPreservesPayload()
    {
        var pcm = new byte[] { 1, 2, 3, 4, 5, 6, 7, 8 };

        var wrapped = WAVEncoder.Wrap(pcm, sampleRate: 48000, channels: 1);

        Assert.Equal(44 + pcm.Length, wrapped.Length);
        Assert.True(WAVEncoder.IsRiff(wrapped));
        Assert.Equal(pcm, wrapped[44..]);
        Assert.Equal((uint)pcm.Length, BinaryPrimitives.ReadUInt32LittleEndian(wrapped.AsSpan(40, 4)));
    }

    [Fact]
    public void Wrap_EmptyPcm_StillProducesAValidHeader()
    {
        var wrapped = WAVEncoder.Wrap([], sampleRate: 48000, channels: 1);

        Assert.Equal(44, wrapped.Length);
        Assert.Equal(0u, BinaryPrimitives.ReadUInt32LittleEndian(wrapped.AsSpan(40, 4)));
        Assert.Equal(36u, BinaryPrimitives.ReadUInt32LittleEndian(wrapped.AsSpan(4, 4)));
    }

    [Fact]
    public void IsRiff_RecognizesOnlyARiffPrefix()
    {
        Assert.True(WAVEncoder.IsRiff("RIFF"u8));
        Assert.True(WAVEncoder.IsRiff("RIFFxxxx"u8));
        Assert.False(WAVEncoder.IsRiff("RIF"u8));       // too short to tell
        Assert.False(WAVEncoder.IsRiff([]));
        Assert.False(WAVEncoder.IsRiff([0, 0, 0, 0]));  // headerless PCM
    }

    [Fact]
    public void PayloadTooLargeForRiff_ThrowsRatherThanTruncating()
    {
        // Past 4 GiB the 32-bit size fields can't describe the payload; silently
        // wrapping would emit a header that lies about the data length.
        Assert.Throws<ArgumentOutOfRangeException>(
            () => WAVEncoder.BuildHeader((long)uint.MaxValue, 48000, 1));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-1)]
    public void NonPositiveFormatValues_Throw(int invalid)
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => WAVEncoder.BuildHeader(100, invalid, 1));
        Assert.Throws<ArgumentOutOfRangeException>(() => WAVEncoder.BuildHeader(100, 48000, invalid));
    }
}
