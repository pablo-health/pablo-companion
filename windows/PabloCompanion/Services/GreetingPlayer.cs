using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace PabloCompanion.Services;

/// <summary>Plays Pablo's greeting for the audio check.</summary>
public interface IGreetingPlayer
{
    /// <summary>
    /// Plays the greeting and completes when it has finished, could not play, or
    /// <paramref name="cancellationToken"/> fires (which stops it).
    /// </summary>
    Task PlayAsync(CancellationToken cancellationToken);
}

/// <summary>
/// Plays the greeting WAV on the default Console render endpoint: the same one
/// a session's loopback capture follows, so hearing it on the loopback proves
/// the path a client's voice takes.
///
/// <para>The greeting ships as a WAV, not AAC: Windows N editions have no Media
/// Foundation, and WAV reads without it. It is converted to the endpoint's mix
/// format here (managed resampler, channel fan-out) so shared-mode WASAPI
/// accepts it without a resampler DMO.</para>
/// </summary>
public sealed class GreetingPlayer : IGreetingPlayer
{
    /// <summary>Where the greeting ships, relative to the app's install folder.</summary>
    public static string DefaultGreetingPath =>
        Path.Combine(AppContext.BaseDirectory, "Assets", "pablo-greeting.wav");

    private readonly string _path;

    public GreetingPlayer()
        : this(DefaultGreetingPath)
    {
    }

    public GreetingPlayer(string path) => _path = path;

    public async Task PlayAsync(CancellationToken cancellationToken)
    {
        WasapiOut? output = null;
        WaveFileReader? reader = null;
        MMDeviceEnumerator? enumerator = null;
        MMDevice? device = null;
        try
        {
            enumerator = new MMDeviceEnumerator();
            device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Console);
            var mix = device.AudioClient.MixFormat;

            reader = new WaveFileReader(_path);
            ISampleProvider samples = reader.ToSampleProvider();
            if (samples.WaveFormat.Channels != 1)
                samples = samples.ToMono();
            if (samples.WaveFormat.SampleRate != mix.SampleRate)
                samples = new WdlResamplingSampleProvider(samples, mix.SampleRate);
            if (mix.Channels > 1)
            {
                var fanOut = new MultiplexingSampleProvider([samples], mix.Channels);
                for (var channel = 0; channel < mix.Channels; channel++)
                    fanOut.ConnectInputToOutput(0, channel);
                samples = fanOut;
            }

            output = new WasapiOut(device, AudioClientShareMode.Shared, true, 100);
            output.Init(samples);
            output.Play();

            while (output.PlaybackState == PlaybackState.Playing && !cancellationToken.IsCancellationRequested)
            {
                try
                {
                    await Task.Delay(100, cancellationToken);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
            }
        }
        catch (Exception ex)
        {
            // No output device, a missing asset: the check carries on and the
            // loopback simply hears nothing, which is the result it reports.
            App.Log($"AudioCheck: greeting did not play type={ex.GetType().Name}");
        }
        finally
        {
            try { output?.Stop(); }
            catch (Exception ex) { App.Log($"AudioCheck: greeting stop failed type={ex.GetType().Name}"); }
            output?.Dispose();
            reader?.Dispose();
            device?.Dispose();
            enumerator?.Dispose();
        }
    }
}
