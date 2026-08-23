using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using OrbitTerm.Presentation;
using OrbitTerm.Terminal;
using Windows.UI;

namespace OrbitTerm.App.Controls;

/// <summary>
/// Renders already-parsed terminal runs. ANSI parsing deliberately lives in
/// OrbitTerm.Terminal so this WinUI control has no protocol or security role.
/// </summary>
public sealed class TerminalLinePresenter : UserControl
{
    private static readonly Color DefaultForeground = Color.FromArgb(255, 215, 222, 232);
    private static readonly Color DefaultBackground = Color.FromArgb(255, 16, 19, 24);
    private readonly RichTextBlock textBlock;
    private TerminalLineViewModel? observedLine;

    public static readonly DependencyProperty LineProperty = DependencyProperty.Register(
        nameof(Line),
        typeof(TerminalLineViewModel),
        typeof(TerminalLinePresenter),
        new PropertyMetadata(null, OnLineChanged));

    public TerminalLinePresenter()
    {
        textBlock = new RichTextBlock
        {
            IsTextSelectionEnabled = true,
            TextWrapping = TextWrapping.NoWrap,
            FontFamily = new FontFamily("Cascadia Mono"),
            FontSize = 13,
        };
        Content = textBlock;
    }

    public TerminalLineViewModel? Line
    {
        get => (TerminalLineViewModel?)GetValue(LineProperty);
        set => SetValue(LineProperty, value);
    }

    private static void OnLineChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args)
    {
        var presenter = (TerminalLinePresenter)sender;
        if (presenter.observedLine is not null)
        {
            presenter.observedLine.PropertyChanged -= presenter.OnLinePropertyChanged;
        }

        presenter.observedLine = args.NewValue as TerminalLineViewModel;
        if (presenter.observedLine is not null)
        {
            presenter.observedLine.PropertyChanged += presenter.OnLinePropertyChanged;
        }

        presenter.RenderLine();
    }

    private void OnLinePropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs args)
    {
        if (args.PropertyName is nameof(TerminalLineViewModel.Text) or nameof(TerminalLineViewModel.Runs) or nameof(TerminalLineViewModel.CursorColumn))
        {
            RenderLine();
        }
    }

    private void RenderLine()
    {
        textBlock.Blocks.Clear();
        var paragraph = new Paragraph { Margin = new Thickness(0) };
        var runs = GetRenderableRuns(Line);
        if (runs is null || runs.Count == 0)
        {
            paragraph.Inlines.Add(new Run { Text = Line?.Text ?? string.Empty });
        }
        else
        {
            foreach (var terminalRun in runs)
            {
                var (foreground, _) = ResolveColors(terminalRun.Style);
                var run = new Run
                {
                    Text = terminalRun.Text,
                    // RichTextBlock.Run does not expose a background brush. Keep
                    // inverse/cursor runs legible until the dedicated canvas
                    // renderer replaces this presentation control.
                    Foreground = new SolidColorBrush(terminalRun.Style.IsInverse ? DefaultForeground : foreground),
                    FontWeight = terminalRun.Style.IsBold || terminalRun.Style.IsInverse ? FontWeights.SemiBold : FontWeights.Normal,
                };
                if (terminalRun.Style.IsUnderlined)
                {
                    var underline = new Underline();
                    underline.Inlines.Add(run);
                    paragraph.Inlines.Add(underline);
                }
                else
                {
                    paragraph.Inlines.Add(run);
                }
            }
        }

        textBlock.Blocks.Add(paragraph);
    }

    private static IReadOnlyList<TerminalTextRun>? GetRenderableRuns(TerminalLineViewModel? line)
    {
        if (line is null || line.Runs.Count == 0 || line.CursorColumn < 0)
        {
            return line?.Runs;
        }

        var runs = line.Runs;

        var cells = new List<(char Character, TerminalStyle Style)>();
        foreach (var run in runs)
        {
            cells.AddRange(run.Text.Select(character => (character, run.Style)));
        }

        while (cells.Count <= line.CursorColumn)
        {
            cells.Add((' ', TerminalStyle.Default));
        }

        var cursor = cells[line.CursorColumn];
        cells[line.CursorColumn] = (cursor.Character, cursor.Style with { IsInverse = !cursor.Style.IsInverse });
        var result = new List<TerminalTextRun>();
        var start = 0;
        var style = cells[0].Style;
        for (var index = 1; index < cells.Count; index++)
        {
            if (cells[index].Style == style)
            {
                continue;
            }

            result.Add(new TerminalTextRun(new string(cells.Skip(start).Take(index - start).Select(cell => cell.Character).ToArray()), style));
            start = index;
            style = cells[index].Style;
        }

        result.Add(new TerminalTextRun(new string(cells.Skip(start).Select(cell => cell.Character).ToArray()), style));
        return result;
    }

    private static (Color Foreground, Color Background) ResolveColors(TerminalStyle style)
    {
        var foreground = ResolveColor(style.Foreground, DefaultForeground);
        var background = ResolveColor(style.Background, DefaultBackground);
        return style.IsInverse ? (background, foreground) : (foreground, background);
    }

    private static Color ResolveColor(TerminalColor color, Color fallback)
    {
        return color.Kind switch
        {
            TerminalColorKind.Default => fallback,
            TerminalColorKind.Standard => StandardPalette[Math.Clamp(color.Value, 0, 7)],
            TerminalColorKind.Bright => BrightPalette[Math.Clamp(color.Value, 0, 7)],
            TerminalColorKind.Indexed => ResolveIndexedColor(color.Value),
            TerminalColorKind.TrueColor => Color.FromArgb(
                255,
                (byte)((color.Value >> 16) & 0xFF),
                (byte)((color.Value >> 8) & 0xFF),
                (byte)(color.Value & 0xFF)),
            _ => fallback,
        };
    }

    private static Color ResolveIndexedColor(int value)
    {
        value = Math.Clamp(value, 0, 255);
        if (value < 8)
        {
            return StandardPalette[value];
        }

        if (value < 16)
        {
            return BrightPalette[value - 8];
        }

        if (value < 232)
        {
            var cube = value - 16;
            var red = cube / 36;
            var green = (cube / 6) % 6;
            var blue = cube % 6;
            return Color.FromArgb(255, CubeComponent(red), CubeComponent(green), CubeComponent(blue));
        }

        var shade = (byte)(8 + ((value - 232) * 10));
        return Color.FromArgb(255, shade, shade, shade);
    }

    private static byte CubeComponent(int value) => value == 0 ? (byte)0 : (byte)(55 + (value * 40));

    private static readonly Color[] StandardPalette =
    [
        Color.FromArgb(255, 40, 44, 52), Color.FromArgb(255, 224, 108, 117),
        Color.FromArgb(255, 152, 195, 121), Color.FromArgb(255, 229, 192, 123),
        Color.FromArgb(255, 97, 175, 239), Color.FromArgb(255, 198, 120, 221),
        Color.FromArgb(255, 86, 182, 194), Color.FromArgb(255, 171, 178, 191),
    ];

    private static readonly Color[] BrightPalette =
    [
        Color.FromArgb(255, 92, 99, 112), Color.FromArgb(255, 255, 126, 138),
        Color.FromArgb(255, 174, 219, 137), Color.FromArgb(255, 255, 214, 133),
        Color.FromArgb(255, 118, 191, 255), Color.FromArgb(255, 219, 142, 244),
        Color.FromArgb(255, 109, 207, 220), Color.FromArgb(255, 238, 242, 248),
    ];
}
