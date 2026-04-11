using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;
using PabloCompanion.ViewModels;
using PabloCompanion.Models;

namespace PabloCompanion.Views;

/// <summary>
/// Wraps a Patient for display in AutoSuggestBox, using the patient's ID
/// to ensure correct selection even when multiple patients share the same name.
/// </summary>
internal record PatientSuggestion(Patient Patient)
{
    public override string ToString() => $"{Patient.FirstName} {Patient.LastName}";
}

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
            .Select(p => new PatientSuggestion(p))
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
            .Select(p => new PatientSuggestion(p))
            .ToList();
    }

    private void PatientSearch_SuggestionChosen(AutoSuggestBox sender, AutoSuggestBoxSuggestionChosenEventArgs args)
    {
        if (args.SelectedItem is PatientSuggestion suggestion)
        {
            sender.Text = suggestion.ToString();
            SelectedPatientId = suggestion.Patient.Id;
            IsPrimaryButtonEnabled = true;
        }
    }
}
