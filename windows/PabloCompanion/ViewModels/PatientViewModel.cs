using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using PabloCompanion.Services;
using uniffi.pablo_core;

namespace PabloCompanion.ViewModels;

/// <summary>
/// Manages patient list, search, and creation.
/// Mirrors PatientViewModel.swift on macOS.
/// </summary>
public partial class PatientViewModel : ObservableObject
{
    private readonly APIClient _apiClient;
    private CancellationTokenSource? _searchDebounce;

    [ObservableProperty]
    public partial Patient[] Patients { get; set; } = [];

    [ObservableProperty]
    public partial bool IsLoading { get; set; }

    [ObservableProperty]
    public partial string? ErrorMessage { get; set; }

    [ObservableProperty]
    public partial string SearchText { get; set; } = "";

    [ObservableProperty]
    public partial bool HasMore { get; set; }

    private uint _currentPage = 1;
    private const uint PageSize = 50;

    public PatientViewModel(APIClient apiClient)
    {
        _apiClient = apiClient;
    }

    partial void OnSearchTextChanged(string value)
    {
        _searchDebounce?.Cancel();
        _searchDebounce?.Dispose();
        _searchDebounce = new CancellationTokenSource();
        _ = DebounceSearchAsync(_searchDebounce.Token);
    }

    private async Task DebounceSearchAsync(CancellationToken token)
    {
        try
        {
            await Task.Delay(300, token);
            _currentPage = 1;
            await LoadPatientsAsync();
        }
        catch (TaskCanceledException) { }
    }

    [RelayCommand]
    public async Task LoadPatientsAsync()
    {
        IsLoading = true;
        ErrorMessage = null;

        try
        {
            var search = string.IsNullOrWhiteSpace(SearchText) ? null : SearchText;
            var response = await _apiClient.FetchPatientsAsync(search, _currentPage, PageSize);
            Patients = response.Data;
            HasMore = response.HasMore;
        }
        catch (PabloException)
        {
            ErrorMessage = "Failed to load patients.";
        }
        catch (Exception)
        {
            ErrorMessage = "Failed to load patients. Check your connection.";
        }
        finally
        {
            IsLoading = false;
        }
    }

    [RelayCommand]
    public async Task LoadMoreAsync()
    {
        if (!HasMore || IsLoading) return;

        _currentPage++;
        IsLoading = true;

        try
        {
            var search = string.IsNullOrWhiteSpace(SearchText) ? null : SearchText;
            var response = await _apiClient.FetchPatientsAsync(search, _currentPage, PageSize);
            Patients = [.. Patients, .. response.Data];
            HasMore = response.HasMore;
        }
        catch (PabloException)
        {
            ErrorMessage = "Failed to load more patients.";
        }
        finally
        {
            IsLoading = false;
        }
    }
}
