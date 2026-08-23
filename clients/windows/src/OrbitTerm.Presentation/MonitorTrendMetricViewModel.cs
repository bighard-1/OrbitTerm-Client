using OrbitTerm.Application.Sessions;

namespace OrbitTerm.Presentation;

/// <summary>
/// A compact, accessibility-friendly monitor trend. It deliberately keeps only
/// rendered text and a bounded sparkline, so a workspace never retains raw
/// command output or an unbounded metrics buffer.
/// </summary>
public sealed class MonitorTrendMetricViewModel : ObservableObject
{
    private readonly Func<MonitorSnapshot, double?> selector;
    private readonly MonitorSampleMetrics requiredMetric;
    private string currentValue = "暂无数据";
    private string sparkline = "—";
    private string accessibilityLabel = "暂无采样";
    private string statisticsSummary = "最小 — · 平均 — · 最大 —";

    public MonitorTrendMetricViewModel(
        string key,
        string label,
        Func<MonitorSnapshot, double?> selector,
        MonitorSampleMetrics requiredMetric = MonitorSampleMetrics.All)
    {
        Key = key;
        Label = label;
        this.selector = selector;
        this.requiredMetric = requiredMetric;
    }

    public string Key { get; }

    public string Label { get; }

    public string CurrentValue
    {
        get => currentValue;
        private set => SetProperty(ref currentValue, value);
    }

    public string Sparkline
    {
        get => sparkline;
        private set => SetProperty(ref sparkline, value);
    }

    public string AccessibilityLabel
    {
        get => accessibilityLabel;
        private set => SetProperty(ref accessibilityLabel, value);
    }

    public string StatisticsSummary
    {
        get => statisticsSummary;
        private set => SetProperty(ref statisticsSummary, value);
    }

    public void Update(IReadOnlyList<MonitorSnapshot> history)
    {
        var values = history
            .Select(snapshot => snapshot.AvailableMetrics.HasFlag(requiredMetric)
                ? selector(snapshot)
                : null)
            .ToArray();
        var available = values.Where(value => value.HasValue).Select(value => value!.Value).ToArray();
        if (available.Length == 0)
        {
            CurrentValue = "暂无数据";
            Sparkline = "—";
            AccessibilityLabel = string.Concat(Label, "，暂无采样");
            StatisticsSummary = "最小 — · 平均 — · 最大 —";
            return;
        }

        var latest = available[^1];
        var probeFailure = ProbeFailurePercent(values);
        CurrentValue = Key == "latency"
            ? values[^1] is double currentLatency
                ? string.Create(
                    System.Globalization.CultureInfo.InvariantCulture,
                    $"{currentLatency:0.#} ms · 失败 {probeFailure:0.#}%")
                : string.Create(
                    System.Globalization.CultureInfo.InvariantCulture,
                    $"-- ms · 失败 {probeFailure:0.#}%")
            : FormatValue(latest);
        Sparkline = BuildSparkline(values, available.Min(), available.Max());
        AccessibilityLabel = string.Concat(Label, "，当前 ", CurrentValue, "，保留 ", available.Length, " 个采样点");
        StatisticsSummary = string.Concat(
            "最小 ", FormatValue(available.Min()),
            " · 平均 ", FormatValue(available.Average()),
            " · 最大 ", FormatValue(available.Max()),
            Key == "latency"
                ? string.Create(
                    System.Globalization.CultureInfo.InvariantCulture,
                    $" · P50 {FormatValue(Percentile(available, 0.50))} · P95 {FormatValue(Percentile(available, 0.95))} · 探测失败 {probeFailure:0.#}%")
                : string.Empty);
    }

    private static double ProbeFailurePercent(IReadOnlyList<double?> samples) =>
        samples.Count == 0
            ? 0
            : samples.Count(value => !value.HasValue) * 100d / samples.Count;

    private static double Percentile(IReadOnlyList<double> values, double percentile)
    {
        var sorted = values.Order().ToArray();
        var rank = Math.Clamp((int)Math.Ceiling(percentile * sorted.Length) - 1, 0, sorted.Length - 1);
        return sorted[rank];
    }

    private string FormatValue(double value) => Key switch
    {
        "download" or "upload" => FormatNetworkRate(value),
        "latency" => string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{value:0.#} ms"),
        _ => string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{value:0.#}%"),
    };

    private static string FormatNetworkRate(double kilobitsPerSecond)
    {
        var safeValue = Math.Max(0, kilobitsPerSecond);
        return safeValue switch
        {
            >= 1_000_000 => string.Create(
                System.Globalization.CultureInfo.InvariantCulture,
                $"{safeValue / 1_000_000:0.##} Gbps"),
            >= 1_000 => string.Create(
                System.Globalization.CultureInfo.InvariantCulture,
                $"{safeValue / 1_000:0.##} Mbps"),
            _ => string.Create(
                System.Globalization.CultureInfo.InvariantCulture,
                $"{safeValue:0.#} Kbps"),
        };
    }

    private static string BuildSparkline(IReadOnlyList<double?> values, double minimum, double maximum)
    {
        const string levels = "▁▂▃▄▅▆▇█";
        var span = Math.Max(maximum - minimum, 0.0001d);
        var text = new System.Text.StringBuilder(values.Count);
        foreach (var value in values)
        {
            if (!value.HasValue)
            {
                text.Append('·');
                continue;
            }

            var level = (int)Math.Round(((value.Value - minimum) / span) * (levels.Length - 1));
            text.Append(levels[Math.Clamp(level, 0, levels.Length - 1)]);
        }

        return text.ToString();
    }
}
