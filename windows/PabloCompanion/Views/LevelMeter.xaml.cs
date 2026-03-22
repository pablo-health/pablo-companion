using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace PabloCompanion.Views;

public sealed partial class LevelMeter : UserControl
{
    private const double MaxBarHeight = 32;

    // Colors designed for visibility on sage green recording banner
    private static readonly SolidColorBrush NormalBrush = new(Windows.UI.Color.FromArgb(255, 255, 255, 255)); // white
    private static readonly SolidColorBrush HoneyBrush = new(Windows.UI.Color.FromArgb(255, 212, 146, 46));  // #D4922E
    private static readonly SolidColorBrush BlushBrush = new(Windows.UI.Color.FromArgb(255, 232, 180, 162)); // #E8B4A2

    public static readonly DependencyProperty LevelProperty = DependencyProperty.Register(
        nameof(Level), typeof(double), typeof(LevelMeter),
        new PropertyMetadata(0.0, OnLevelChanged));

    public static readonly DependencyProperty LabelProperty = DependencyProperty.Register(
        nameof(Label), typeof(string), typeof(LevelMeter),
        new PropertyMetadata("Mic", OnLabelChanged));

    public double Level
    {
        get => (double)GetValue(LevelProperty);
        set => SetValue(LevelProperty, value);
    }

    public string Label
    {
        get => (string)GetValue(LabelProperty);
        set => SetValue(LabelProperty, value);
    }

    public LevelMeter()
    {
        InitializeComponent();
    }

    private static void OnLevelChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is LevelMeter meter)
            meter.UpdateBar();
    }

    private static void OnLabelChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is LevelMeter meter)
            meter.LabelText.Text = (string)e.NewValue;
    }

    private void UpdateBar()
    {
        double clamped = Math.Clamp(Level, 0.0, 1.0);
        FillBar.Height = clamped * MaxBarHeight;

        FillBar.Background = clamped switch
        {
            <= 0.5 => NormalBrush,
            <= 0.8 => HoneyBrush,
            _ => BlushBrush,
        };

        AutomationProperties.SetName(FillBar, $"Audio level {(int)(clamped * 100)} percent");
    }
}
