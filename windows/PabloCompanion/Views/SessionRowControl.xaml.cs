using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using PabloCompanion.Helpers;
using PabloCompanion.ViewModels;
using uniffi.pablo_core;

namespace PabloCompanion.Views;

public sealed partial class SessionRowControl : UserControl
{
    public event EventHandler<Session>? SessionTapped;

    public SessionRowControl()
    {
        InitializeComponent();
        DataContextChanged += OnDataContextChanged;
    }

    private void OnDataContextChanged(FrameworkElement sender, DataContextChangedEventArgs args)
    {
        if (args.NewValue is Session session)
        {
            var patients = App.Services.GetRequiredService<PatientViewModel>().Patients;
            PatientName.Text = SessionFormatting.FormatPatientName(session, patients);
            InitialsText.Text = SessionFormatting.GetPatientInitials(session, patients);
            SessionTime.Text = SessionFormatting.FormatTime(session);
            DurationText.Text = $"· {SessionFormatting.FormatDuration(session)}";
            Badge.Status = session.Status;

            // Show recording indicator if this session is actively recording
            var recordingVm = App.Services.GetRequiredService<RecordingViewModel>();
            RecordingIndicator.Visibility = recordingVm.ActiveSessionId == session.Id
                ? Visibility.Visible
                : Visibility.Collapsed;

            // Platform icon
            var platformGlyph = SessionFormatting.GetPlatformIcon(session);
            if (!string.IsNullOrEmpty(platformGlyph))
            {
                PlatformIcon.Glyph = platformGlyph;
                PlatformIcon.Visibility = Visibility.Visible;
                ToolTipService.SetToolTip(PlatformIcon, SessionFormatting.GetPlatformName(session));
            }
            else
            {
                PlatformIcon.Visibility = Visibility.Collapsed;
            }

            // Action button
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

    private void Row_PointerPressed(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e)
    {
        // Don't fire SessionTapped when the action button (Start/End) is clicked
        if (e.OriginalSource is FrameworkElement source && IsChildOf(source, ActionButton))
            return;

        if (DataContext is Session session)
        {
            SessionTapped?.Invoke(this, session);
        }
    }

    private static bool IsChildOf(DependencyObject child, DependencyObject parent)
    {
        var current = child;
        while (current != null)
        {
            if (current == parent) return true;
            current = VisualTreeHelper.GetParent(current);
        }
        return false;
    }

    private void Row_PointerEntered(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e)
    {
        ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.Hand);
    }

    private void Row_PointerExited(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e)
    {
        ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.Arrow);
    }
}
