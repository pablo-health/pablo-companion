using PabloCompanion.Core;

namespace PabloCompanion.Helpers;

/// <summary>How the client audio indicator's dot is coloured.</summary>
public enum ClientAudioTone
{
    /// <summary>The client is reaching the recording.</summary>
    Good,

    /// <summary>Normal at the start of a call: the client may not have spoken yet (honey).</summary>
    Waiting,

    /// <summary>System audio is missing or the client can't be heard (blush).</summary>
    Problem,
}

/// <summary>
/// What the recording banner's client audio indicator says. Mirrors
/// <c>ClientAudioIndicator.swift</c>, which replaced a "System audio" dot that
/// only said a source existed and stayed lit while the call went unheard.
/// </summary>
public readonly record struct ClientAudioIndicatorState(string Label, ClientAudioTone Tone)
{
    public const string HearingClientLabel = "Hearing client";
    public const string WaitingLabel = "Waiting for client audio";
    public const string NoClientAudioLabel = "No client audio";
    public const string NoSystemAudioLabel = "No system audio";

    /// <param name="systemAudioInterrupted">
    /// System audio has stopped reaching the recording
    /// (<see cref="ViewModels.RecordingViewModel.SystemAudioInterrupted"/>). That
    /// outranks the monitor: with no system audio at all there is no client to hear.
    /// </param>
    /// <param name="status">The monitor's judgement of what is arriving.</param>
    public static ClientAudioIndicatorState For(bool systemAudioInterrupted, ClientAudioStatus status)
    {
        if (systemAudioInterrupted) return new(NoSystemAudioLabel, ClientAudioTone.Problem);
        return status switch
        {
            ClientAudioStatus.HearingClient => new(HearingClientLabel, ClientAudioTone.Good),
            ClientAudioStatus.NoClientAudio => new(NoClientAudioLabel, ClientAudioTone.Problem),
            _ => new(WaitingLabel, ClientAudioTone.Waiting),
        };
    }
}
