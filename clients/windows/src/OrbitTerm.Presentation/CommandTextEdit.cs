namespace OrbitTerm.Presentation;

public sealed record CommandTextEdit(
    int CaretIndex,
    bool RemovedControlCharacters,
    bool ConvertedMultiline);
