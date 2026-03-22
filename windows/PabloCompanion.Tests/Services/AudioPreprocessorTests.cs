using System.Buffers.Binary;
using PabloCompanion.Services;

namespace PabloCompanion.Tests.Services;

public class AudioPreprocessorTests
{
    private static string WritePcmFile(short[] samples)
    {
        var path = Path.Combine(Path.GetTempPath(), $"pablo_test_{Guid.NewGuid()}.pcm");
        var bytes = new byte[samples.Length * 2];
        for (int i = 0; i < samples.Length; i++)
            BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(i * 2, 2), samples[i]);
        File.WriteAllBytes(path, bytes);
        return path;
    }

    [Fact]
    public async Task Mono48kDecimatesTo16k()
    {
        var samples = new short[48000]; // 1 second @ 48kHz
        samples[0] = 16384;
        var path = WritePcmFile(samples);

        try
        {
            var result = await AudioPreprocessor.PreprocessMicPcmAsync(path, 48000);

            // Should produce roughly 16000 samples (1 second @ 16kHz)
            Assert.InRange(result.Length, 15000, 17000);
            // All values in [-1.0, 1.0]
            Assert.All(result, s => Assert.InRange(s, -1.0f, 1.0f));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task StereoDownmixProducesOutput()
    {
        // Stereo: L=8192, R=-8192 → mono should be ~0
        var samples = new short[48000 * 2];
        for (int i = 0; i < 48000; i++)
        {
            samples[i * 2] = 8192;
            samples[i * 2 + 1] = -8192;
        }
        var path = WritePcmFile(samples);

        try
        {
            var result = await AudioPreprocessor.PreprocessSystemPcmAsync(path, 2, 48000);

            Assert.InRange(result.Length, 15000, 17000);
            // L and R cancel → near zero
            Assert.All(result, s => Assert.InRange(s, -0.01f, 0.01f));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task EmptyFileReturnsEmpty()
    {
        var path = WritePcmFile([]);
        try
        {
            var result = await AudioPreprocessor.PreprocessMicPcmAsync(path, 48000);
            Assert.Empty(result);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task Already16kSkipsDecimation()
    {
        var samples = new short[16000];
        for (int i = 0; i < 16000; i++)
            samples[i] = (short)(i % 100);
        var path = WritePcmFile(samples);

        try
        {
            var result = await AudioPreprocessor.PreprocessMicPcmAsync(path, 16000);

            // Exact count — no decimation
            Assert.Equal(16000, result.Length);
            // Verify normalization: sample[1] = 1/32768
            Assert.InRange(result[1], 1.0f / 32768 - 1e-6f, 1.0f / 32768 + 1e-6f);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task InvalidChannelCountThrows()
    {
        var path = WritePcmFile(new short[100]);
        try
        {
            await Assert.ThrowsAsync<ArgumentException>(() =>
                AudioPreprocessor.PreprocessPcmAsync(path, 5, 48000));
        }
        finally
        {
            File.Delete(path);
        }
    }
}
