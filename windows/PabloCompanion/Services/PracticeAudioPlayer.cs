using NAudio.Wave;

namespace PabloCompanion.Services;

/// <summary>
/// Plays Pablo Bear's response audio through system speakers.
/// Receives PCM chunks (24kHz, 16-bit, mono) from the WebSocket client
/// and queues them for playback via WASAPI. Playing through system audio
/// means AudioCaptureKit will capture it as the "client" channel automatically.
/// </summary>
public sealed class PracticeAudioPlayer : IDisposable
{
    private const int SampleRate = 24_000;
    private const int BitsPerSample = 16;
    private const int Channels = 1;

    private readonly BufferedWaveProvider _buffer;
    private WasapiOut? _player;
    private readonly object _lock = new();
    private bool _isPlaying;

    /// <summary>
    /// Current RMS level for waveform visualization (0.0–1.0).
    /// </summary>
    public event Action<float>? LevelUpdated;

    public PracticeAudioPlayer()
    {
        var format = new WaveFormat(SampleRate, BitsPerSample, Channels);
        _buffer = new BufferedWaveProvider(format)
        {
            BufferDuration = TimeSpan.FromSeconds(5),
            DiscardOnBufferOverflow = true,
        };
    }

    public void Start()
    {
        lock (_lock)
        {
            if (_isPlaying) return;

            _player = new WasapiOut(NAudio.CoreAudioApi.AudioClientShareMode.Shared, 50);
            _player.Init(_buffer);
            _player.Play();
            _isPlaying = true;
        }
    }

    public void Stop()
    {
        lock (_lock)
        {
            if (!_isPlaying) return;
            _isPlaying = false;
        }

        _player?.Stop();
        _player?.Dispose();
        _player = null;
        _buffer.ClearBuffer();
    }

    /// <summary>
    /// Queue a PCM chunk for immediate playback.
    /// </summary>
    public void Enqueue(byte[] pcmData)
    {
        if (pcmData.Length < 2) return;

        _buffer.AddSamples(pcmData, 0, pcmData.Length);

        // Compute RMS for waveform visualization
        ComputeAndFireRms(pcmData);
    }

    public void Dispose() => Stop();

    private void ComputeAndFireRms(byte[] pcmData)
    {
        int sampleCount = pcmData.Length / 2;
        if (sampleCount == 0) return;

        float sum = 0;
        for (int i = 0; i < sampleCount; i++)
        {
            short sample = BitConverter.ToInt16(pcmData, i * 2);
            float normalized = sample / 32768f;
            sum += normalized * normalized;
        }

        float rms = MathF.Sqrt(sum / sampleCount);
        LevelUpdated?.Invoke(rms);
    }
}
