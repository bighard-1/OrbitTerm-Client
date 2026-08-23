namespace OrbitTerm.Presentation;

public sealed record SftpRecentOperationViewModel(
    string TimeText,
    string ContextText,
    string KindText,
    string Title,
    string Message)
{
    public string AccessibilityDescription => string.Concat(
        TimeText,
        "，",
        ContextText,
        "，",
        KindText,
        "，",
        Title,
        "，",
        Message);
}
