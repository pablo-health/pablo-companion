using CommunityToolkit.Mvvm.ComponentModel;
using PabloCompanion.Core;
using PabloCompanion.Models;
using PabloCompanion.Services;

namespace PabloCompanion.ViewModels;

/// <summary>What the minimal window shows before a start arms anything.</summary>
public enum ConsentPromptKind
{
    /// <summary>Nothing: the start goes ahead (or nothing is pending).</summary>
    None,

    /// <summary>Nobody has asked the client: "Start recording and ask" or "Don't record".</summary>
    AskOnRecording,

    /// <summary>The client declined: the declined message, "Open chart" and "Close".</summary>
    Declined,
}

/// <summary>
/// The client's answer about AI-assisted notes, read before the microphone arms,
/// and the answer given on the recording once it has.
///
/// When the practice asks its clients, a client who declined stops the start. A
/// client nobody has asked yet, in person or over telehealth, gets two choices:
/// ask once recording starts ("Start recording and ask"), or don't record. The
/// answer is then given on the recording and saved from the asking panel shown
/// there. With the setting off the consent is always
/// <see cref="RecordingConsent.Clear"/>, no prompt appears, and Start Session is
/// one click as before.
///
/// A failed read does not block the start: the server refuses a declined
/// client's recording, and a telehealth client nobody has asked, on its own, and
/// those refusals turn into the same prompts here rather than a generic error.
///
/// Mirrors <c>RecordingConsentViewModel.swift</c>, <c>AskOnRecordingViewModel.swift</c>
/// and the start flow in <c>ContentView+RecordingConsent.swift</c> on macOS.
/// </summary>
public partial class RecordingConsentViewModel : ObservableObject
{
    private readonly APIClient _apiClient;
    private readonly SessionViewModel _sessionVm;
    private readonly TranscriptionViewModel _transcriptionVm;

    /// <summary>
    /// Bumped on every check and reset, so a slow read for a start the clinician
    /// already cancelled cannot overwrite a newer one.
    /// </summary>
    private int _generation;

    private RecordingConsentCheck? _check;

    public RecordingConsentViewModel(APIClient apiClient, SessionViewModel sessionVm,
        TranscriptionViewModel transcriptionVm)
    {
        _apiClient = apiClient;
        _sessionVm = sessionVm;
        _transcriptionVm = transcriptionVm;
    }

    // --- Before arming ---

    /// <summary>The appointment a prompt or a handoff confirmation is waiting on.</summary>
    [ObservableProperty]
    public partial string? PendingAppointmentId { get; private set; }

    /// <summary>The client's answer, as it bears on recording. Clear until read.</summary>
    [ObservableProperty]
    public partial RecordingConsent Consent { get; private set; } = RecordingConsent.ClearValue;

    /// <summary>The answer is being read.</summary>
    [ObservableProperty]
    public partial bool IsChecking { get; private set; }

    /// <summary>Which prompt to show, if any.</summary>
    public ConsentPromptKind Prompt => PendingAppointmentId is null
        ? ConsentPromptKind.None
        : Consent switch
        {
            RecordingConsent.AskOnRecording => ConsentPromptKind.AskOnRecording,
            RecordingConsent.Declined => ConsentPromptKind.Declined,
            _ => ConsentPromptKind.None,
        };

    /// <summary>"This client declined AI-assisted notes on ..." for the declined prompt.</summary>
    public string DeclinedMessage => Consent is RecordingConsent.Declined declined
        ? RecordingConsentCopy.Declined(declined.On)
        : "";

    /// <summary>The client the answer belongs to; opens their chart from the declined prompt.</summary>
    public string? PatientId => _check?.PatientId;

    // --- Once recording has started ---

    /// <summary>The session being asked about on the recording; null when no ask is on screen.</summary>
    [ObservableProperty]
    public partial string? AskSessionId { get; private set; }

    /// <summary>The client the answer is saved to. Null: record it on the chart in the web app.</summary>
    [ObservableProperty]
    public partial string? AskPatientId { get; private set; }

    /// <summary>The practice's retention window, read aloud. Null when not known: no script is shown.</summary>
    [ObservableProperty]
    public partial int? AskRetentionDays { get; private set; }

    /// <summary>Where the session is; the answer is saved as given there.</summary>
    [ObservableProperty]
    public partial AiConsentModality AskModality { get; private set; }

    [ObservableProperty]
    public partial AiConsentGiver Giver { get; set; } = AiConsentGiver.Client;

    /// <summary>Where the client said they were, in their words. Telehealth only, optional.</summary>
    [ObservableProperty]
    public partial string Location { get; set; } = "";

    [ObservableProperty]
    public partial bool IsSaving { get; private set; }

    [ObservableProperty]
    public partial string? SaveError { get; private set; }

    /// <summary>
    /// The client declined and the recording was stopped and deleted; the panel
    /// says so in place of the script.
    /// </summary>
    [ObservableProperty]
    public partial bool RecordingDeleted { get; private set; }

    public bool IsAsking => AskSessionId is not null;

    /// <summary>Whether the panel asks where the client is: telehealth only.</summary>
    public bool AsksLocation => IsAsking && AskModality == AiConsentModality.Telehealth;

    /// <summary>The script to read aloud, or none when the retention window is unknown.</summary>
    public IReadOnlyList<string> ScriptLines => AskRetentionDays is { } days ? ConsentScript.Lines(days) : [];

    partial void OnLocationChanged(string value)
    {
        if (value.Length > AiConsentAnswer.LocationMaxLength)
            Location = value[..AiConsentAnswer.LocationMaxLength];
    }

    // --- Flows ---

    /// <summary>
    /// Start Session from the minimal window's card. A client who is clear starts
    /// at once, as before; a declined client, or one nobody has asked yet, gets
    /// the prompt instead.
    /// </summary>
    public async Task RequestStartAsync(string appointmentId, string? patientId, AiConsentModality? modality)
    {
        if (IsChecking || Prompt != ConsentPromptKind.None || _sessionVm.StartingAppointmentId is not null) return;

        var consent = await CheckAsync(appointmentId, patientId, modality, webAlreadyAsked: false, webAskingOnRecording: false);
        if (consent is null) return;
        if (consent is RecordingConsent.Clear)
        {
            Reset();
            await StartAsync(appointmentId, ask: null);
        }
        else
        {
            PendingAppointmentId = appointmentId;
            Notify();
        }
    }

    /// <summary>
    /// A start handed off from the web app. Reads the answer with what the web
    /// start already chose. Returns the consent: for <see cref="RecordingConsent.Clear"/>
    /// and <see cref="RecordingConsent.AskingOnRecording"/> the caller shows its
    /// Start Recording confirmation and calls <see cref="ConfirmHandoffAsync"/>;
    /// otherwise <see cref="Prompt"/> is now showing. Null when the read was
    /// replaced before it finished; nothing is pending then.
    /// </summary>
    public async Task<RecordingConsent?> CheckHandoffAsync(string appointmentId, AiConsentModality? modality,
        bool webAlreadyAsked, bool webAskingOnRecording)
    {
        var consent = await CheckAsync(appointmentId, patientId: null, modality, webAlreadyAsked, webAskingOnRecording);
        if (consent is null) return null;
        PendingAppointmentId = appointmentId;
        Notify();
        return consent;
    }

    /// <summary>
    /// The handoff confirmation's Start Recording: start, asking on the recording
    /// when the web start chose "Ask now". A confirmation left open while another
    /// start replaced its read starts as a plain start; the server still refuses
    /// what the answer does not allow, and that refusal brings the prompt back.
    /// </summary>
    public async Task ConfirmHandoffAsync(string appointmentId)
    {
        var ask = PendingAppointmentId == appointmentId ? PendingAsk() : null;
        if (PendingAppointmentId == appointmentId) Reset();
        await StartAsync(appointmentId, ask);
    }

    private async Task ConfirmPendingAsync()
    {
        if (PendingAppointmentId is not { } appointmentId) return;
        var ask = PendingAsk();
        Reset();
        await StartAsync(appointmentId, ask);
    }

    /// <summary>
    /// "Start recording and ask": start, telling the server the clinician asks on
    /// the recording; the script follows once recording is running.
    /// </summary>
    public async Task StartAndAskAsync()
    {
        if (PendingAppointmentId is null || Consent is not RecordingConsent.AskOnRecording ask) return;
        Consent = new RecordingConsent.AskingOnRecording(ask.Modality);
        if (_check is not null) _check = _check with { Consent = Consent };
        await ConfirmPendingAsync();
    }

    /// <summary>"Don't record" / "Close": nothing is started and nothing is written.</summary>
    public void DismissPrompt() => Reset();

    /// <summary>
    /// Saves the answer given on the recording. An agreement closes the panel. A
    /// decline first stops and deletes the recording, so nothing of it is uploaded
    /// whether or not the answer saves, and the panel then says so. A failed save
    /// stays on the panel with its message.
    /// </summary>
    public async Task AnswerAsync(string decision)
    {
        if (AskSessionId is not { } sessionId || IsSaving) return;

        if (decision == AiConsentEntry.DeclinedDecision && !RecordingDeleted)
        {
            if (await DiscardDeclinedRecordingAsync(sessionId))
                RecordingDeleted = true;
            Notify();
        }

        if (!await RecordAsync(decision)) return;
        if (decision != AiConsentEntry.DeclinedDecision) CloseAsk();
    }

    /// <summary>Closes the asking panel without saving an answer here.</summary>
    public void CloseAsk()
    {
        AskSessionId = null;
        AskPatientId = null;
        AskRetentionDays = null;
        Location = "";
        SaveError = null;
        RecordingDeleted = false;
        Notify();
    }

    /// <summary>Clears everything; called on sign-out.</summary>
    public void ClearAllData()
    {
        Reset();
        CloseAsk();
    }

    // --- internal ---

    /// <summary>
    /// Reads the setting and the client's answer. Never throws: a failure is
    /// treated as clear, because the server still refuses what the answer does
    /// not allow. Null when a newer check or a reset (a cancel, a sign-out)
    /// replaced this one while it was reading: the caller then does nothing.
    /// </summary>
    private async Task<RecordingConsent?> CheckAsync(string appointmentId, string? patientId,
        AiConsentModality? modality, bool webAlreadyAsked, bool webAskingOnRecording)
    {
        var current = ++_generation;
        IsChecking = true;
        try
        {
            var read = await _apiClient.CheckRecordingConsentAsync(appointmentId, patientId, modality);
            if (current != _generation) return null;
            var consent = read.Consent.HandedOff(webAlreadyAsked, webAskingOnRecording);
            _check = read with { Consent = consent };
            Consent = consent;
            return consent;
        }
        catch (Exception ex)
        {
            if (current != _generation) return null;
            // Type only: a response could carry PHI.
            App.Log($"Consent check failed: {ex.GetType().Name}");
            _check = null;
            Consent = RecordingConsent.ClearValue;
            return Consent;
        }
        finally
        {
            if (current == _generation) IsChecking = false;
            Notify();
        }
    }

    /// <summary>What the start in hand asks once recording starts; null unless the clinician chose to.</summary>
    private OnRecordingAsk? PendingAsk() => Consent.AskingModality is { } modality
        ? new OnRecordingAsk(_check?.PatientId, _check is { AsksClients: true } check ? check.AudioRetentionDays : null, modality)
        : null;

    /// <summary>
    /// Creates the session and arms recording. When the server refuses over the
    /// client's answer (it changed after the check, or was never read), nothing was
    /// created and nothing arms: the prompt comes back with the declined message,
    /// or with "Start recording and ask" and "Don't record".
    /// </summary>
    private async Task StartAsync(string appointmentId, OnRecordingAsk? ask)
    {
        var outcome = await _sessionVm.StartAppointmentSessionAsync(appointmentId, ask is not null);
        switch (outcome.Kind)
        {
            case AppointmentStartKind.Started when outcome.Recording && ask is not null && outcome.SessionId is { } sessionId:
                BeginAsk(sessionId, ask);
                break;

            case AppointmentStartKind.Declined:
                ShowServerAnswer(new RecordingConsent.Declined(outcome.DeclinedOn ?? ""));
                PendingAppointmentId = appointmentId;
                Notify();
                break;

            case AppointmentStartKind.ConsentNeeded:
                // Read again, so "Start recording and ask" knows the client and the
                // practice's retention window; the server has said what the answer is.
                var read = await CheckAsync(appointmentId, patientId: null, AiConsentModality.Telehealth,
                    webAlreadyAsked: false, webAskingOnRecording: false);
                if (read is null) break;
                if (read is not RecordingConsent.AskOnRecording)
                    ShowServerAnswer(new RecordingConsent.AskOnRecording(AiConsentModality.Telehealth));
                PendingAppointmentId = appointmentId;
                Notify();
                break;
        }
    }

    /// <summary>
    /// The server's answer in place of the read one. With no earlier read the
    /// retention window is unknown, so no script is offered rather than one that
    /// names the wrong window.
    /// </summary>
    private void ShowServerAnswer(RecordingConsent consent)
    {
        _generation++;
        IsChecking = false;
        _check = new RecordingConsentCheck(consent, _check is not null, _check?.AudioRetentionDays ?? 0, _check?.PatientId);
        Consent = consent;
    }

    private void BeginAsk(string sessionId, OnRecordingAsk ask)
    {
        AskSessionId = sessionId;
        AskPatientId = ask.PatientId;
        AskRetentionDays = ask.RetentionDays;
        AskModality = ask.Modality;
        Giver = AiConsentGiver.Client;
        Location = "";
        IsSaving = false;
        SaveError = null;
        RecordingDeleted = false;
        Notify();
    }

    /// <summary>
    /// The client declined on the recording: stop capture, delete every segment
    /// and anything that could upload it, and return the session to a hand-written
    /// note. Returns false, deleting nothing, when that session is no longer the
    /// one recording.
    /// </summary>
    private async Task<bool> DiscardDeclinedRecordingAsync(string sessionId)
    {
        var recorder = _sessionVm.Recorder;
        if (recorder.ActiveSessionId != sessionId) return false;

        // Still the active session while capture stops, so the last segment is
        // filed under it and deleted with the rest.
        try
        {
            await recorder.StopAsync();
        }
        catch (Exception ex)
        {
            App.LogException("RecordingConsent.StopDeclined", ex);
        }
        _transcriptionVm.DiscardDeclined(sessionId);
        await _sessionVm.ReturnToHandWrittenAsync(sessionId);
        await _sessionVm.LoadTodayAppointmentsAsync();
        return true;
    }

    /// <summary>Saves the answer. True when saved; false leaves <see cref="SaveError"/> set.</summary>
    private async Task<bool> RecordAsync(string decision)
    {
        if (AskPatientId is not { } patientId) return false;
        var answer = new AiConsentAnswer(decision, AskModality, Giver, AsksLocation ? Location : null);

        IsSaving = true;
        SaveError = null;
        Notify();
        try
        {
            await _apiClient.RecordConsentAsync(answer, patientId);
            return true;
        }
        catch (Exception ex)
        {
            App.Log($"Recording consent answer failed: {ex.GetType().Name}");
            SaveError = RecordingConsentCopy.SaveFailed;
            return false;
        }
        finally
        {
            IsSaving = false;
            Notify();
        }
    }

    private void Reset()
    {
        _generation++;
        IsChecking = false;
        _check = null;
        Consent = RecordingConsent.ClearValue;
        PendingAppointmentId = null;
        Notify();
    }

    /// <summary>Raises the derived properties the views read.</summary>
    private void Notify()
    {
        OnPropertyChanged(nameof(Prompt));
        OnPropertyChanged(nameof(DeclinedMessage));
        OnPropertyChanged(nameof(PatientId));
        OnPropertyChanged(nameof(IsAsking));
        OnPropertyChanged(nameof(AsksLocation));
        OnPropertyChanged(nameof(ScriptLines));
    }

    /// <summary>What to ask once recording has started, carried from the prompt to the start.</summary>
    private sealed record OnRecordingAsk(string? PatientId, int? RetentionDays, AiConsentModality Modality);
}
