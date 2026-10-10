using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using PabloCompanion.Core;

namespace PabloCompanion.Views;

/// <summary>
/// A vertical audio level meter. <see cref="Level"/> is the linear RMS
/// AudioCaptureKit reports (0-1); the bar is drawn on a decibel scale
/// (<see cref="AudioLevelScale"/>), -60 dBFS empty to 0 dBFS full. Mirrors
/// <c>LevelMeter.swift</c>.
/// </summary>
public sealed partial class LevelMeter : UserControl
{
    private const double MaxBarHeight = 32;

    // The Mac draws ordinary levels in sage. This meter sits on the sage
    // recording banner, where a sage bar would vanish, so ordinary levels are
    // white here; honey and blush come from the palette.
    private static readonly SolidColorBrush NormalBrush = new(Windows.UI.Color.FromArgb(255, 255, 255, 255));

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
        var fraction = AudioLevelScale.DisplayFraction((float)Level);
        FillBar.Height = fraction * MaxBarHeight;

        // Thresholds sit near the top of the decibel scale: normal speech lands
        // mid-bar, honey from about -12 dBFS, blush from -6 dBFS (close to clipping).
        FillBar.Background = fraction switch
        {
            > 0.9f => (Brush)Application.Current.Resources["PabloBlush"],
            > 0.8f => (Brush)Application.Current.Resources["PabloHoney"],
            _ => NormalBrush,
        };

        AutomationProperties.SetName(FillBar, $"Audio level {(int)(fraction * 100)} percent");
    }
}
