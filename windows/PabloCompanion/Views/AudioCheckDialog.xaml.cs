using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using PabloCompanion.Helpers;
using PabloCompanion.ViewModels;

namespace PabloCompanion.Views;

/// <summary>
/// "Say hello to Pablo": the under-a-minute first-use audio check. Mirrors
/// <c>AudioCheckView.swift</c>. Shown from the minimal window once, and from
/// Settings > Check audio.
/// </summary>
public sealed partial class AudioCheckDialog : ContentDialog
{
    private const string CheckedGlyph = "\uEC61";
    private const string UncheckedGlyph = "\uEA3A";

    private readonly AudioCheckViewModel _model;
    private readonly string? _micDeviceId;
    private AudioCheckStep? _announced;

    public AudioCheckDialog(string? micDeviceId)
        : this(new AudioCheckViewModel(), micDeviceId)
    {
    }

    internal AudioCheckDialog(AudioCheckViewModel model, string? micDeviceId)
    {
        _model = model;
        _micDeviceId = micDeviceId;
        InitializeComponent();
        ComputerText.Text = AudioCheckCopy.HeardComputer;
        YouText.Text = AudioCheckCopy.HeardYou;
        _model.PropertyChanged += Model_PropertyChanged;
        Closed += Dialog_Closed;
        Render();
    }

    private void Model_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (DispatcherQueue.HasThreadAccess) Render();
        else DispatcherQueue.TryEnqueue(Render);
    }

    private void Render()
    {
        switch (_model.Step)
        {
            case AudioCheckStep.Intro:
                SetText(AudioCheckCopy.IntroTitle, AudioCheckCopy.IntroCaption, checks: false);
                SetButtons(primary: AudioCheckCopy.Start, secondary: null, close: AudioCheckCopy.DoItLater);
                break;
            case AudioCheckStep.Greeting:
                SetText(AudioCheckCopy.GreetingTitle, AudioCheckCopy.GreetingCaption, checks: true);
                SetButtons(primary: null, secondary: null, close: AudioCheckCopy.Cancel);
                break;
            case AudioCheckStep.YourTurn:
                SetText(AudioCheckCopy.YourTurnTitle, null, checks: true);
                SetButtons(primary: null, secondary: null, close: AudioCheckCopy.Cancel);
                break;
            case AudioCheckStep.Done:
                RenderResult();
                break;
        }
        SetCheck(ComputerRow, ComputerIcon, _model.HeardComputer, AudioCheckCopy.HeardComputer);
        SetCheck(YouRow, YouIcon, _model.HeardYou, AudioCheckCopy.HeardYou);
        Announce(_model.Step);
    }

    private void RenderResult()
    {
        switch (_model.StartFailure)
        {
            case AudioCheckStartFailure.MicrophonePermission:
                SetText(AudioCheckCopy.MicPermissionTitle, AudioCheckCopy.MicPermissionCaption, checks: false);
                SetButtons(AudioCheckCopy.TryAgain, AudioCheckCopy.OpenSettings, AudioCheckCopy.DoItLater);
                return;
            case AudioCheckStartFailure.Other:
                SetText(AudioCheckCopy.StartFailedTitle, AudioCheckCopy.StartFailedCaption, checks: false);
                SetButtons(AudioCheckCopy.TryAgain, null, AudioCheckCopy.DoItLater);
                return;
        }

        if (_model.Passed)
        {
            SetText(AudioCheckCopy.PassedTitle, AudioCheckCopy.PassedCaption, checks: true);
            SetButtons(AudioCheckCopy.Done, null, null);
        }
        else if (!_model.HeardComputer)
        {
            SetText(AudioCheckCopy.NoComputerTitle, AudioCheckCopy.NoComputerCaption, checks: true);
            SetButtons(AudioCheckCopy.TryAgain, AudioCheckCopy.OpenSettings, AudioCheckCopy.DoItLater);
        }
        else
        {
            SetText(AudioCheckCopy.NoYouTitle, AudioCheckCopy.NoYouCaption, checks: true);
            SetButtons(AudioCheckCopy.TryAgain, AudioCheckCopy.OpenSettings, AudioCheckCopy.DoItLater);
        }
    }

    private void SetText(string heading, string? caption, bool checks)
    {
        HeadingText.Text = heading;
        CaptionText.Text = caption ?? "";
        CaptionText.Visibility = caption is null ? Visibility.Collapsed : Visibility.Visible;
        ChecksPanel.Visibility = checks ? Visibility.Visible : Visibility.Collapsed;
    }

    private void SetButtons(string? primary, string? secondary, string? close)
    {
        PrimaryButtonText = primary ?? "";
        SecondaryButtonText = secondary ?? "";
        CloseButtonText = close ?? "";
        DefaultButton = primary is null ? ContentDialogButton.None : ContentDialogButton.Primary;
    }

    private static void SetCheck(FrameworkElement row, FontIcon icon, bool done, string text)
    {
        icon.Glyph = done ? CheckedGlyph : UncheckedGlyph;
        icon.Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources[done ? "PabloSage" : "PabloBrownSoft"];
        AutomationProperties.SetName(row, $"{text} {(done ? "Done" : "Not yet")}");
    }

    private void Announce(AudioCheckStep step)
    {
        if (_announced == step) return;
        _announced = step;
        var message = step switch
        {
            AudioCheckStep.Greeting => "Listen for Pablo",
            AudioCheckStep.YourTurn => "Your turn. Say hello, Pablo.",
            AudioCheckStep.Done => _model.Passed ? "You're all set" : "The audio check found a problem",
            _ => "",
        };
        if (message.Length == 0) return;
        var peer = FrameworkElementAutomationPeer.FromElement(HeadingText)
            ?? FrameworkElementAutomationPeer.CreatePeerForElement(HeadingText);
        peer?.RaiseNotificationEvent(
            AutomationNotificationKind.Other,
            AutomationNotificationProcessing.ImportantMostRecent,
            message,
            "AudioCheck");
    }

    // --- Buttons ---

    private void Primary_Click(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        // "Done" closes; "Start" and "Try again" run the check in place.
        if (_model.Step == AudioCheckStep.Done && _model.Passed) return;
        args.Cancel = true;
        Start();
    }

    private async void Secondary_Click(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        args.Cancel = true;
        var micProblem = _model.StartFailure == AudioCheckStartFailure.MicrophonePermission
            || (_model.HeardComputer && !_model.HeardYou);
        var uri = micProblem ? RecordingStartFailure.MicrophoneSettingsUri : AudioCheckCopy.VolumeMixerUri;
        try
        {
            await Windows.System.Launcher.LaunchUriAsync(new Uri(uri));
        }
        catch (Exception ex)
        {
            App.LogException("AudioCheck.OpenSettings", ex);
        }
    }

    private void Close_Click(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        // Closing ends the check; Dialog_Closed cleans up.
    }

    private async void Start()
    {
        _announced = null;
        try
        {
            await _model.RunAsync(_micDeviceId);
        }
        catch (Exception ex)
        {
            App.LogException("AudioCheck.Run", ex);
        }
    }

    private async void Dialog_Closed(ContentDialog sender, ContentDialogClosedEventArgs args)
    {
        _model.PropertyChanged -= Model_PropertyChanged;
        try
        {
            await _model.CancelAsync();
        }
        catch (Exception ex)
        {
            App.LogException("AudioCheck.Cancel", ex);
        }
    }
}
