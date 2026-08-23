using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;

namespace OrbitTerm.App.Controls;

// Hallmark · component: telemetry line · genre: modern-minimal · theme: Cobalt
// states: data · empty · focus · high-DPI
// The compact header keeps operational telemetry visible without consuming the terminal workspace.
public sealed class MonitorTrendLine : Canvas
{
    private static readonly Color LineColor = Color.FromArgb(255, 20, 108, 197);
    private static readonly Color EmptyColor = Color.FromArgb(255, 135, 148, 166);

    public static readonly DependencyProperty SparklineProperty = DependencyProperty.Register(
        nameof(Sparkline),
        typeof(string),
        typeof(MonitorTrendLine),
        new PropertyMetadata(string.Empty, OnSparklineChanged));

    public MonitorTrendLine()
    {
        SizeChanged += (_, _) => RenderTrend();
        IsHitTestVisible = false;
    }

    public string Sparkline
    {
        get => (string)GetValue(SparklineProperty);
        set => SetValue(SparklineProperty, value);
    }

    private static void OnSparklineChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args) =>
        ((MonitorTrendLine)sender).RenderTrend();

    private void RenderTrend()
    {
        Children.Clear();
        var points = Decode(Sparkline);
        if (ActualWidth <= 0 || ActualHeight <= 0 || points.Count < 2)
        {
            AddEmptyLine();
            return;
        }

        var polyline = new Polyline
        {
            Stroke = new SolidColorBrush(LineColor),
            StrokeThickness = 1.6,
            StrokeLineJoin = PenLineJoin.Round,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
        };
        var width = Math.Max(1, ActualWidth - 2);
        var height = Math.Max(1, ActualHeight - 3);
        for (var division = 1; division <= 3; division++)
        {
            var y = 1 + (height * division / 4d);
            Children.Add(new Line
            {
                X1 = 1,
                X2 = width + 1,
                Y1 = y,
                Y2 = y,
                Stroke = new SolidColorBrush(Color.FromArgb(38, 135, 148, 166)),
                StrokeThickness = 1,
                StrokeDashArray = [2, 3],
            });
        }
        for (var index = 0; index < points.Count; index++)
        {
            var x = 1 + width * index / Math.Max(1, points.Count - 1);
            var y = 1 + height * (1 - points[index] / 7d);
            polyline.Points.Add(new Windows.Foundation.Point(x, y));
        }

        Children.Add(polyline);
    }

    private void AddEmptyLine()
    {
        if (ActualWidth <= 0 || ActualHeight <= 0)
        {
            return;
        }

        Children.Add(new Line
        {
            X1 = 1,
            X2 = Math.Max(1, ActualWidth - 1),
            Y1 = ActualHeight / 2,
            Y2 = ActualHeight / 2,
            Stroke = new SolidColorBrush(EmptyColor),
            StrokeThickness = 1,
            StrokeDashArray = [2, 2],
        });
    }

    private static List<int> Decode(string? value)
    {
        const string levels = "▁▂▃▄▅▆▇█";
        var result = new List<int>();
        foreach (var character in value ?? string.Empty)
        {
            var level = levels.IndexOf(character);
            if (level >= 0)
            {
                result.Add(level);
            }
        }

        return result;
    }
}
