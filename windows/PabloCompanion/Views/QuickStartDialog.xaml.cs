using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;
using PabloCompanion.ViewModels;
using uniffi.pablo_core;

namespace PabloCompanion.Views;

public sealed partial class QuickStartDialog : ContentDialog
{
    private readonly PatientViewModel _patientVm;
    private Patient[] _allPatients = [];

    public string? SelectedPatientId { get; private set; }

    public QuickStartDialog()
    {
        InitializeComponent();
        _patientVm = App.Services.GetRequiredService<PatientViewModel>();
        _allPatients = _patientVm.Patients;

        // Show all patients immediately
        PatientSearch.ItemsSource = _allPatients
            .Select(p => $"{p.FirstName} {p.LastName}")
            .ToList();
    }

    private void PatientSearch_TextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (args.Reason != AutoSuggestionBoxTextChangeReason.UserInput) return;

        var query = sender.Text?.Trim() ?? "";
        var filtered = string.IsNullOrEmpty(query)
            ? _allPatients
            : _allPatients.Where(p =>
                p.FirstName.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                p.LastName.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                $"{p.FirstName} {p.LastName}".Contains(query, StringComparison.OrdinalIgnoreCase))
              .ToArray();

        sender.ItemsSource = filtered
            .Select(p => $"{p.FirstName} {p.LastName}")
            .ToList();
    }

    private void PatientSearch_SuggestionChosen(AutoSuggestBox sender, AutoSuggestBoxSuggestionChosenEventArgs args)
    {
        var selected = args.SelectedItem?.ToString();
        if (selected == null) return;

        var patient = _allPatients.FirstOrDefault(p => $"{p.FirstName} {p.LastName}" == selected);
        if (patient != null)
        {
            SelectedPatientId = patient.Id;
            IsPrimaryButtonEnabled = true;
        }
    }
}
