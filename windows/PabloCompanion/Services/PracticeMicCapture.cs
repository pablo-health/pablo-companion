using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace PabloCompanion.Services;

/// <summary>
/// Captures mic audio and delivers 16kHz 16-bit mono PCM frames for WebSocket streaming.
/// Runs independently of AudioCaptureKit — both can tap the mic simultaneously.
/// </summary>
public sealed class PracticeMicCapture : IDisposable
{
    private const int TargetSampleRate = 16_000;
    private const int FrameDurationMs = 20;
    private const int FrameSamples = TargetSampleRate * FrameDurationMs / 1000; // 320
    private const int FrameBytes = FrameSamples * 2; // 640 bytes (16-bit)

    private WasapiCapture? _capture;
    private readonly object _lock = new();
    private byte[] _accumulator = [];
    private int _accumulatorLength;
    private bool _isCapturing;

    // Resampling state
    private int _hardwareSampleRate;
    private int _hardwareChannels;

    /// <summary>
    /// Called with 20ms PCM chunks (640 bytes = 320 samples at 16kHz, 16-bit mono).
    /// </summary>
    public event Action<byte[]>? AudioFrameReady;

    /// <summary>
    /// Current mic RMS level for visualization (0.0–1.0).
    /// </summary>
    public event Action<float>? LevelUpdated;

    public bool IsCapturing
    {
        get { lock (_lock) return _isCapturing; }
    }

    public void Start(string? micDeviceId = null)
    {
        lock (_lock)
        {
            if (_isCapturing) return;
        }

        MMDevice? device = null;
        if (micDeviceId != null)
        {
            using var enumerator = new MMDeviceEnumerator();
            try { device = enumerator.GetDevice(micDeviceId); }
            catch { /* fall through to default */ }
        }

        _capture = device != null
            ? new WasapiCapture(device, true, 20)
            : new WasapiCapture(WasapiCapture.GetDefaultCaptureDevice(), true, 20);

        _hardwareSampleRate = _capture.WaveFormat.SampleRate;
        _hardwareChannels = _capture.WaveFormat.Channels;

        _accumulator = new byte[FrameBytes * 4]; // pre-allocate room for ~4 frames
        _accumulatorLength = 0;

        _capture.DataAvailable += OnDataAvailable;
        _capture.StartRecording();

        lock (_lock) _isCapturing = true;
    }

    public void Stop()
    {
        lock (_lock)
        {
            if (!_isCapturing) return;
            _isCapturing = false;
        }

        _capture?.StopRecording();
        _capture?.Dispose();
        _capture = null;
        _accumulatorLength = 0;
    }

    public void Dispose() => Stop();

    private void OnDataAvailable(object? sender, WaveInEventArgs e)
    {
        if (e.BytesRecorded == 0) return;

        // Convert hardware format to 16kHz mono 16-bit
        var mono16k = ConvertTo16kMono(e.Buffer, e.BytesRecorded);
        if (mono16k.Length == 0) return;

        // Compute RMS for level meter
        ComputeAndFireRms(mono16k);

        // Accumulate and emit 20ms frames
        lock (_lock)
        {
            EnsureAccumulatorCapacity(mono16k.Length);
            Buffer.BlockCopy(mono16k, 0, _accumulator, _accumulatorLength, mono16k.Length);
            _accumulatorLength += mono16k.Length;

            while (_accumulatorLength >= FrameBytes)
            {
                var frame = new byte[FrameBytes];
                Buffer.BlockCopy(_accumulator, 0, frame, 0, FrameBytes);
                _accumulatorLength -= FrameBytes;
                Buffer.BlockCopy(_accumulator, FrameBytes, _accumulator, 0, _accumulatorLength);

                AudioFrameReady?.Invoke(frame);
            }
        }
    }

    private byte[] ConvertTo16kMono(byte[] buffer, int bytesRecorded)
    {
        // Input: hardware format (likely 48kHz, 16-bit or 32-bit float, 1-2 channels)
        var format = _capture!.WaveFormat;
        int bytesPerSample = format.BitsPerSample / 8;
        int totalSamples = bytesRecorded / bytesPerSample;
        int totalFrames = totalSamples / _hardwareChannels;

        // Decimation ratio (integer: 48000/16000 = 3)
        int ratio = _hardwareSampleRate / TargetSampleRate;
        if (ratio < 1) ratio = 1;

        int outputFrames = totalFrames / ratio;
        var output = new byte[outputFrames * 2]; // 16-bit mono output

        for (int i = 0; i < outputFrames; i++)
        {
            int srcFrame = i * ratio;
            float sample;

            if (format.Encoding == WaveFormatEncoding.IeeeFloat && bytesPerSample == 4)
            {
                // 32-bit float input
                float sum = 0;
                for (int ch = 0; ch < _hardwareChannels; ch++)
                {
                    int offset = (srcFrame * _hardwareChannels + ch) * 4;
                    if (offset + 4 <= bytesRecorded)
                        sum += BitConverter.ToSingle(buffer, offset);
                }
                sample = sum / _hardwareChannels;
            }
            else
            {
                // 16-bit PCM input
                float sum = 0;
                for (int ch = 0; ch < _hardwareChannels; ch++)
                {
                    int offset = (srcFrame * _hardwareChannels + ch) * 2;
                    if (offset + 2 <= bytesRecorded)
                        sum += BitConverter.ToInt16(buffer, offset) / 32768f;
                }
                sample = sum / _hardwareChannels;
            }

            // Clamp and convert to 16-bit
            sample = Math.Clamp(sample, -1f, 1f);
            short pcm16 = (short)(sample * 32767f);
            output[i * 2] = (byte)(pcm16 & 0xFF);
            output[i * 2 + 1] = (byte)((pcm16 >> 8) & 0xFF);
        }

        return output;
    }

    private void ComputeAndFireRms(byte[] mono16bitPcm)
    {
        int sampleCount = mono16bitPcm.Length / 2;
        if (sampleCount == 0) return;

        float sum = 0;
        for (int i = 0; i < sampleCount; i++)
        {
            short sample = BitConverter.ToInt16(mono16bitPcm, i * 2);
            float normalized = sample / 32768f;
            sum += normalized * normalized;
        }

        float rms = MathF.Sqrt(sum / sampleCount);
        LevelUpdated?.Invoke(rms);
    }

    private void EnsureAccumulatorCapacity(int additionalBytes)
    {
        int required = _accumulatorLength + additionalBytes;
        if (required > _accumulator.Length)
        {
            var newBuf = new byte[required * 2];
            Buffer.BlockCopy(_accumulator, 0, newBuf, 0, _accumulatorLength);
            _accumulator = newBuf;
        }
    }
}
