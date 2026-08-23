using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;

namespace OrbitTerm.App.Controls;

/// <summary>Small, accessible status pill for a remote Docker container.</summary>
public sealed class DockerStateBadge : UserControl
{
    private readonly Border frame = new();
    public static readonly DependencyProperty StateProperty = DependencyProperty.Register(
        nameof(State), typeof(string), typeof(DockerStateBadge), new PropertyMetadata(string.Empty, OnStateChanged));

    public DockerStateBadge()
    {
        frame.Padding = new Thickness(6, 2, 7, 2);
        frame.CornerRadius = new CornerRadius(8);
        Content = frame;
        Render();
    }

    public string State
    {
        get => (string)GetValue(StateProperty);
        set => SetValue(StateProperty, value);
    }

    private static void OnStateChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args) =>
        ((DockerStateBadge)sender).Render();

    private void Render()
    {
        var (label, color) = State.Trim().ToLowerInvariant() switch
        {
            "running" => ("运行中", Color.FromArgb(255, 31, 132, 87)),
            "paused" => ("已暂停", Color.FromArgb(255, 191, 120, 0)),
            "restarting" => ("重启中", Color.FromArgb(255, 35, 105, 191)),
            "exited" => ("已停止", Color.FromArgb(255, 112, 122, 138)),
            "created" => ("已创建", Color.FromArgb(255, 91, 105, 126)),
            "dead" => ("不可用", Color.FromArgb(255, 192, 54, 54)),
            _ => (string.IsNullOrWhiteSpace(State) ? "未知" : State, Color.FromArgb(255, 112, 122, 138)),
        };
        frame.Background = new SolidColorBrush(Color.FromArgb(24, color.R, color.G, color.B));
        frame.BorderBrush = new SolidColorBrush(Color.FromArgb(90, color.R, color.G, color.B));
        frame.BorderThickness = new Thickness(1);
        AutomationProperties.SetName(this, string.Concat("容器状态：", label));

        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5 };
        panel.Children.Add(new Ellipse { Width = 7, Height = 7, Fill = new SolidColorBrush(color), VerticalAlignment = VerticalAlignment.Center });
        panel.Children.Add(new TextBlock { Text = label, Foreground = new SolidColorBrush(color), FontSize = 11, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        frame.Child = panel;
    }
}
