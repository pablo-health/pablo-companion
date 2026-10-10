using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using PabloCompanion.Core;
using PabloCompanion.Models;
using PabloCompanion.ViewModels;

namespace PabloCompanion.Views;

/// <summary>
/// The asking panel shown in the minimal window once recording has started for a
/// client nobody had asked about AI-assisted notes. Renders
/// <see cref="RecordingConsentViewModel"/>'s ask state; the view model does the
/// work (saving the answer, and on a decline stopping and deleting the
/// recording). Mirrors <c>AskOnRecordingView.swift</c>.
/// </summary>
public sealed partial class AskOnRecordingPanel : UserControl
{
    private static readonly AiConsentGiver[] Givers = [AiConsentGiver.Client, AiConsentGiver.Parent, AiConsentGiver.Guardian];

    private RecordingConsentViewModel? _viewModel;
    private bool _rendering;

    public AskOnRecordingPanel()
    {
        InitializeComponent();

        TitleText.Text = RecordingConsentCopy.AskingTitle;
        AutomationProperties.SetName(this, RecordingConsentCopy.AskingTitle);
        PromptText.Text = RecordingConsentCopy.AskingPrompt;
        DeletedText.Text = RecordingConsentCopy.RecordingDeleted;
        RecordOnChartText.Text = RecordingConsentCopy.RecordOnChart;
        LocationLabel.Text = RecordingConsentCopy.LocationLabel;
        AutomationProperties.SetName(LocationBox, RecordingConsentCopy.LocationLabel);
        GiverPicker.Header = RecordingConsentCopy.AnsweredBy;
        AutomationProperties.SetName(GiverPicker, RecordingConsentCopy.AnsweredBy);
        GiverPicker.ItemsSource = Givers.Select(g => g.Word()).ToList();
        CloseButton.Content = RecordingConsentCopy.Close;
        AutomationProperties.SetName(CloseButton, RecordingConsentCopy.Close);
    }

    /// <summary>Attaches the view model; the panel re-renders on every change.</summary>
    public void Bind(RecordingConsentViewModel viewModel)
    {
        if (_viewModel is not null) _viewModel.PropertyChanged -= ViewModel_PropertyChanged;
        _viewModel = viewModel;
        _viewModel.PropertyChanged += ViewModel_PropertyChanged;
        Render();
    }

    private void ViewModel_PropertyChanged(object? sender, PropertyChangedEventArgs e)
        => DispatcherQueue.TryEnqueue(Render);

    private void Render()
    {
        if (_viewModel is not { } vm) return;
        _rendering = true;
        try
        {
            Visibility = vm.IsAsking ? Visibility.Visible : Visibility.Collapsed;
            if (!vm.IsAsking) return;

            var knowsClient = vm.AskPatientId is not null;
            DeletedText.Visibility = Show(vm.RecordingDeleted);
            AskContent.Visibility = Show(!vm.RecordingDeleted);

            var lines = vm.ScriptLines;
            ScriptBlock.Visibility = Show(lines.Count > 0);
            ScriptLines.ItemsSource = lines;

            AnswerControls.Visibility = Show(knowsClient);
            AnswerControls.IsHitTestVisible = !vm.IsSaving;
            GiverPicker.IsEnabled = !vm.IsSaving;
            GiverPicker.SelectedIndex = Array.IndexOf(Givers, vm.Giver);
            LocationBlock.Visibility = Show(vm.AsksLocation);
            LocationBox.IsEnabled = !vm.IsSaving;
            if (LocationBox.Text != vm.Location) LocationBox.Text = vm.Location;
            RecordOnChartText.Visibility = Show(!knowsClient);

            SaveErrorText.Text = vm.SaveError ?? "";
            SaveErrorText.Visibility = Show(vm.SaveError is not null);

            var agreed = RecordingConsentCopy.Answered(AiConsentEntry.ConsentedDecision, vm.Giver);
            var declined = RecordingConsentCopy.Answered(AiConsentEntry.DeclinedDecision, vm.Giver);
            AgreedButton.Content = vm.IsSaving ? "Saving..." : agreed;
            AutomationProperties.SetName(AgreedButton, agreed);
            DeclinedButton.Content = declined;
            AutomationProperties.SetName(DeclinedButton, declined);

            if (vm.RecordingDeleted)
            {
                // Only a decline that could not be saved is left to do.
                AgreedButton.Visibility = Visibility.Collapsed;
                DeclinedButton.Visibility = Show(vm.SaveError is not null);
            }
            else
            {
                AgreedButton.Visibility = Show(knowsClient);
                DeclinedButton.Visibility = Show(knowsClient);
            }
            AgreedButton.IsEnabled = !vm.IsSaving;
            DeclinedButton.IsEnabled = !vm.IsSaving;
            CloseButton.IsEnabled = !vm.IsSaving;
        }
        finally
        {
            _rendering = false;
        }
    }

    private static Visibility Show(bool visible) => visible ? Visibility.Visible : Visibility.Collapsed;

    private void GiverPicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_rendering || _viewModel is null) return;
        if (GiverPicker.SelectedIndex is var index && index >= 0 && index < Givers.Length)
            _viewModel.Giver = Givers[index];
    }

    private void LocationBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_rendering || _viewModel is null) return;
        _viewModel.Location = LocationBox.Text;
    }

    private async void Agreed_Click(object sender, RoutedEventArgs e) => await AnswerAsync(AiConsentEntry.ConsentedDecision);

    private async void Declined_Click(object sender, RoutedEventArgs e) => await AnswerAsync(AiConsentEntry.DeclinedDecision);

    private async Task AnswerAsync(string decision)
    {
        if (_viewModel is null) return;
        try
        {
            await _viewModel.AnswerAsync(decision);
        }
        catch (Exception ex)
        {
            App.LogException("AskOnRecordingPanel.Answer", ex);
        }
    }

    private void Close_Click(object sender, RoutedEventArgs e) => _viewModel?.CloseAsk();
}
