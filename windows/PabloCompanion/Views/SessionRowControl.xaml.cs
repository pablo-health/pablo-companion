using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PabloCompanion.Helpers;
using PabloCompanion.ViewModels;
using uniffi.pablo_core;

namespace PabloCompanion.Views;

public sealed partial class SessionRowControl : UserControl
{
    public SessionRowControl()
    {
        InitializeComponent();
        DataContextChanged += OnDataContextChanged;
    }

    private void OnDataContextChanged(FrameworkElement sender, DataContextChangedEventArgs args)
    {
        if (args.NewValue is Session session)
        {
            PatientName.Text = SessionFormatting.FormatPatientName(session);
            SessionTime.Text = SessionFormatting.FormatTime(session);
            Badge.Status = session.Status;

            switch (session.Status)
            {
                case SessionStatus.Scheduled:
                    ActionButton.Content = "Start";
                    ActionButton.Style = (Style)Application.Current.Resources["PabloPrimaryButton"];
                    ActionButton.Visibility = Visibility.Visible;
                    break;
                case SessionStatus.InProgress:
                    ActionButton.Content = "End";
                    ActionButton.Style = (Style)Application.Current.Resources["PabloDestructiveButton"];
                    ActionButton.Visibility = Visibility.Visible;
                    break;
                default:
                    ActionButton.Visibility = Visibility.Collapsed;
                    break;
            }
        }
    }

    private async void ActionButton_Click(object sender, RoutedEventArgs e)
    {
        if (DataContext is not Session session) return;

        var vm = App.Services.GetRequiredService<SessionViewModel>();

        if (session.Status == SessionStatus.Scheduled)
        {
            await vm.StartSessionAsync(session.Id);
        }
        else if (session.Status == SessionStatus.InProgress)
        {
            await vm.EndSessionAsync(session.Id);
        }
    }
}
