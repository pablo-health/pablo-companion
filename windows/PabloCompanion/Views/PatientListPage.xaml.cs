using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using PabloCompanion.ViewModels;
using uniffi.pablo_core;

namespace PabloCompanion.Views;

public sealed partial class PatientListPage : Page
{
    private readonly PatientViewModel _viewModel;

    public PatientListPage()
    {
        InitializeComponent();
        _viewModel = App.Services.GetRequiredService<PatientViewModel>();
        _viewModel.PropertyChanged += ViewModel_PropertyChanged;
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        await _viewModel.LoadPatientsAsync();
        UpdateUI();
    }

    private void ViewModel_PropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        DispatcherQueue.TryEnqueue(UpdateUI);
    }

    private void UpdateUI()
    {
        LoadingRing.IsActive = _viewModel.IsLoading;
        PatientList.ItemsSource = _viewModel.Patients;
    }

    private void SearchBox_TextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (args.Reason == AutoSuggestionBoxTextChangeReason.UserInput)
        {
            _viewModel.SearchText = sender.Text;
        }
    }
}
