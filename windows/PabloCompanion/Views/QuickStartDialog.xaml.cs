using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;
using PabloCompanion.Services;
using uniffi.pablo_core;

namespace PabloCompanion.Views;

public sealed partial class QuickStartDialog : ContentDialog
{
    private readonly APIClient _apiClient;
    private Patient[] _patients = [];
    private CancellationTokenSource? _searchDebounce;

    public string? SelectedPatientId { get; private set; }

    public QuickStartDialog()
    {
        InitializeComponent();
        _apiClient = App.Services.GetRequiredService<APIClient>();
    }

    private void PatientSearch_TextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (args.Reason != AutoSuggestionBoxTextChangeReason.UserInput) return;

        _searchDebounce?.Cancel();
        _searchDebounce = new CancellationTokenSource();
        _ = DebounceSearchAsync(sender, _searchDebounce.Token);
    }

    private async Task DebounceSearchAsync(AutoSuggestBox sender, CancellationToken token)
    {
        try
        {
            await Task.Delay(300, token);
            if (token.IsCancellationRequested) return;

            SearchProgress.IsActive = true;

            var search = string.IsNullOrWhiteSpace(sender.Text) ? null : sender.Text;
            var response = await _apiClient.FetchPatientsAsync(search, 1, 10);

            if (token.IsCancellationRequested) return;

            _patients = response.Data;
            sender.ItemsSource = _patients.Select(p => $"{p.FirstName} {p.LastName}").ToList();
        }
        catch (TaskCanceledException) { }
        catch
        {
            if (!token.IsCancellationRequested)
            {
                sender.ItemsSource = new List<string> { "Error loading patients" };
            }
        }
        finally
        {
            SearchProgress.IsActive = false;
        }
    }

    private void PatientSearch_SuggestionChosen(AutoSuggestBox sender, AutoSuggestBoxSuggestionChosenEventArgs args)
    {
        var selected = args.SelectedItem?.ToString();
        if (selected == null) return;

        var patient = _patients.FirstOrDefault(p => $"{p.FirstName} {p.LastName}" == selected);
        if (patient != null)
        {
            SelectedPatientId = patient.Id;
            IsPrimaryButtonEnabled = true;
        }
    }
}
