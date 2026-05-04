using Microsoft.UI.Xaml.Controls;
using PabloCompanion.ViewModels;

namespace PabloCompanion.Views;

public sealed partial class PracticeEndedContent : UserControl
{
    public PracticeEndedContent(PracticeViewModel viewModel)
    {
        InitializeComponent();

        TopicText.Text = viewModel.SelectedTopic?.Name ?? "Practice Session";

        var totalSeconds = viewModel.EndedDurationSeconds;
        var minutes = totalSeconds / 60;
        var seconds = totalSeconds % 60;
        DurationText.Text = $"{minutes}:{seconds:D2}";
    }
}
