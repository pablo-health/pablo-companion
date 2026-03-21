using System.Buffers.Binary;

namespace PabloCompanion.Services;

/// <summary>
/// Converts raw PCM audio (signed 16-bit LE) to mono float normalized at 16 kHz.
/// Port of core/src/audio_preprocessing.rs — uses simple block-average decimation
/// instead of rubato (good enough for Whisper, avoids native dependency).
/// </summary>
public static class AudioPreprocessor
{
    private const int TargetSampleRate = 16000;

    /// <summary>
    /// Preprocess a mic PCM sidecar (mono, 48 kHz i16 LE) to 16 kHz mono float.
    /// </summary>
    public static async Task<float[]> PreprocessMicPcmAsync(string path, int sampleRate = 48000)
    {
        return await PreprocessPcmAsync(path, channels: 1, sampleRate);
    }

    /// <summary>
    /// Preprocess a system audio PCM sidecar (stereo interleaved, 48 kHz i16 LE) to 16 kHz mono float.
    /// </summary>
    public static async Task<float[]> PreprocessSystemPcmAsync(string path, int channels = 2, int sampleRate = 48000)
    {
        return await PreprocessPcmAsync(path, channels, sampleRate);
    }

    /// <summary>
    /// Read raw PCM (i16 LE), downmix to mono if stereo, decimate to 16 kHz.
    /// </summary>
    internal static async Task<float[]> PreprocessPcmAsync(string path, int channels, int sampleRate)
    {
        if (channels < 1 || channels > 2)
            throw new ArgumentException($"Unsupported channel count: {channels} (expected 1 or 2)");
        if (sampleRate <= 0)
            throw new ArgumentException("Sample rate must be > 0");

        var rawBytes = await File.ReadAllBytesAsync(path);
        if (rawBytes.Length == 0)
            return [];

        if (rawBytes.Length % 2 != 0)
            throw new InvalidOperationException("PCM file has odd byte count; expected 16-bit (2 bytes per sample)");

        int totalSamples = rawBytes.Length / 2;

        // Parse i16 samples and convert to f32 normalized [-1.0, 1.0]
        var samplesF32 = new float[totalSamples];
        for (int i = 0; i < totalSamples; i++)
        {
            short sample = BinaryPrimitives.ReadInt16LittleEndian(rawBytes.AsSpan(i * 2, 2));
            samplesF32[i] = sample / 32768.0f;
        }

        // Downmix stereo to mono
        float[] mono;
        if (channels == 2)
        {
            if (totalSamples % 2 != 0)
                throw new InvalidOperationException("Stereo PCM has odd sample count; expected interleaved L/R pairs");

            int frameCount = totalSamples / 2;
            mono = new float[frameCount];
            for (int i = 0; i < frameCount; i++)
            {
                mono[i] = (samplesF32[i * 2] + samplesF32[i * 2 + 1]) / 2.0f;
            }
        }
        else
        {
            mono = samplesF32;
        }

        if (mono.Length == 0)
            return [];

        // Skip decimation if already at target rate
        if (sampleRate == TargetSampleRate)
            return mono;

        // Decimate via block average (e.g. 48kHz -> 16kHz = 3:1)
        return Decimate(mono, sampleRate, TargetSampleRate);
    }

    /// <summary>
    /// Simple block-average decimation. For integer ratios (48k->16k = 3:1),
    /// averages each block of N input samples into one output sample.
    /// </summary>
    internal static float[] Decimate(float[] input, int inputRate, int outputRate)
    {
        double ratio = (double)inputRate / outputRate;
        int outputLen = (int)(input.Length / ratio);
        if (outputLen == 0)
            return [];

        var output = new float[outputLen];
        for (int i = 0; i < outputLen; i++)
        {
            double srcStart = i * ratio;
            double srcEnd = (i + 1) * ratio;
            int start = (int)srcStart;
            int end = Math.Min((int)srcEnd, input.Length);

            if (end <= start)
            {
                output[i] = start < input.Length ? input[start] : 0f;
                continue;
            }

            float sum = 0;
            for (int j = start; j < end; j++)
                sum += input[j];
            output[i] = sum / (end - start);
        }

        return output;
    }
}
