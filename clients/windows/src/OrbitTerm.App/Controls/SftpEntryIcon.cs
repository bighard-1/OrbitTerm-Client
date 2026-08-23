using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace OrbitTerm.App.Controls;

/// <summary>
/// Explorer-inspired remote entry icon. It deliberately avoids shell-association
/// extraction: a remote filename must never cause the client to execute or load
/// an arbitrary local handler.
/// </summary>
public sealed class SftpEntryIcon : Grid
{
    public static readonly DependencyProperty IsDirectoryProperty = DependencyProperty.Register(
        nameof(IsDirectory), typeof(bool), typeof(SftpEntryIcon), new PropertyMetadata(false, OnVisualPropertyChanged));

    public static readonly DependencyProperty FileNameProperty = DependencyProperty.Register(
        nameof(FileName), typeof(string), typeof(SftpEntryIcon), new PropertyMetadata(string.Empty, OnVisualPropertyChanged));

    public SftpEntryIcon()
    {
        Width = 30;
        Height = 30;
        HorizontalAlignment = HorizontalAlignment.Center;
        VerticalAlignment = VerticalAlignment.Center;
        Render();
    }

    public bool IsDirectory
    {
        get => (bool)GetValue(IsDirectoryProperty);
        set => SetValue(IsDirectoryProperty, value);
    }

    public string FileName
    {
        get => (string)GetValue(FileNameProperty);
        set => SetValue(FileNameProperty, value);
    }

    private static void OnVisualPropertyChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args) =>
        ((SftpEntryIcon)sender).Render();

    private void Render()
    {
        Children.Clear();
        ToolTipService.SetToolTip(this, IsDirectory ? "文件夹" : FileKindLabel(FileName));
        AutomationProperties.SetName(this, IsDirectory ? "文件夹" : string.Concat("文件，", FileKindLabel(FileName)));

        if (IsDirectory)
        {
            var folder = new Grid();
            folder.Children.Add(new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(255, 239, 184, 56)),
                BorderBrush = new SolidColorBrush(Color.FromArgb(255, 193, 136, 16)),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(3),
                Margin = new Thickness(1, 8, 1, 2),
            });
            folder.Children.Add(new Border
            {
                Width = 13,
                Height = 8,
                Background = new SolidColorBrush(Color.FromArgb(255, 239, 184, 56)),
                BorderBrush = new SolidColorBrush(Color.FromArgb(255, 193, 136, 16)),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(3, 3, 0, 0),
                HorizontalAlignment = HorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(3, 3, 0, 0),
            });
            Children.Add(folder);
            return;
        }

        var (label, accent) = FileStyle(FileName);
        var page = new Grid { Width = 23, Height = 27, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        page.Children.Add(new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(255, 250, 252, 255)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(255, 156, 171, 194)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(2),
        });
        page.Children.Add(new Border
        {
            Height = 7,
            Background = new SolidColorBrush(accent),
            VerticalAlignment = VerticalAlignment.Bottom,
            CornerRadius = new CornerRadius(0, 0, 2, 2),
        });
        page.Children.Add(new TextBlock
        {
            Text = label,
            Foreground = new SolidColorBrush(accent),
            FontSize = 7,
            FontWeight = Microsoft.UI.Text.FontWeights.Bold,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        });
        Children.Add(page);
    }

    private static string FileKindLabel(string name) => FileStyle(name).Label;

    private static (string Label, Color Accent) FileStyle(string name)
    {
        var extension = System.IO.Path.GetExtension(name).ToLowerInvariant();
        return extension switch
        {
            ".txt" or ".log" or ".md" or ".conf" or ".ini" or ".yaml" or ".yml" => ("TXT", Color.FromArgb(255, 45, 113, 194)),
            ".json" or ".xml" or ".html" or ".css" or ".js" or ".ts" or ".cs" or ".rs" or ".py" or ".sh" => ("CODE", Color.FromArgb(255, 126, 87, 194)),
            ".jpg" or ".jpeg" or ".png" or ".gif" or ".webp" or ".bmp" or ".svg" => ("IMG", Color.FromArgb(255, 18, 133, 116)),
            ".mp3" or ".wav" or ".flac" or ".m4a" or ".ogg" => ("AUD", Color.FromArgb(255, 204, 100, 34)),
            ".mp4" or ".mkv" or ".mov" or ".avi" or ".webm" => ("VID", Color.FromArgb(255, 197, 68, 82)),
            ".zip" or ".gz" or ".tar" or ".bz2" or ".xz" or ".7z" or ".rar" => ("ZIP", Color.FromArgb(255, 109, 91, 78)),
            ".pdf" => ("PDF", Color.FromArgb(255, 205, 62, 62)),
            ".doc" or ".docx" => ("DOC", Color.FromArgb(255, 45, 113, 194)),
            ".xls" or ".xlsx" => ("XLS", Color.FromArgb(255, 33, 129, 78)),
            ".ppt" or ".pptx" => ("PPT", Color.FromArgb(255, 211, 91, 41)),
            _ => ("FILE", Color.FromArgb(255, 100, 115, 136)),
        };
    }
}
