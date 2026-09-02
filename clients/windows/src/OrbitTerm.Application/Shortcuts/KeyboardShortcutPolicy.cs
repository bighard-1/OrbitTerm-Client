namespace OrbitTerm.Application.Shortcuts;

[Flags]
public enum ShortcutModifiers
{
    None = 0,
    Control = 1,
    Shift = 2,
    Alt = 4,
}

public enum AppShortcutAction
{
    NewWorkspaceTab,
    CloseWorkspaceTab,
    DisconnectAndCloseWorkspaceTab,
    SearchTerminal,
    FocusCommandInput,
    SendCommandInput,
    OpenSettings,
    OpenBatchCommand,
    ToggleAssetSidebar,
    ToggleToolInspector,
    ToggleTerminalFullscreen,
    SelectWorkspaceTab1,
    SelectWorkspaceTab2,
    SelectWorkspaceTab3,
    SelectWorkspaceTab4,
    SelectWorkspaceTab5,
    SelectWorkspaceTab6,
    SelectWorkspaceTab7,
    SelectWorkspaceTab8,
    SelectWorkspaceTab9,
    SelectTerminalPane1,
    SelectTerminalPane2,
    SelectTerminalPane3,
    SelectTerminalPane4,
}

public sealed record KeyboardShortcutGesture(string Key, ShortcutModifiers Modifiers)
{
    public string DisplayText
    {
        get
        {
            var parts = new List<string>(4);
            if (Modifiers.HasFlag(ShortcutModifiers.Control)) parts.Add("Ctrl");
            if (Modifiers.HasFlag(ShortcutModifiers.Shift)) parts.Add("Shift");
            if (Modifiers.HasFlag(ShortcutModifiers.Alt)) parts.Add("Alt");
            parts.Add(KeyboardShortcutCatalog.DisplayKey(Key));
            return string.Join("+", parts);
        }
    }
}

public sealed record KeyboardShortcutDefinition(
    AppShortcutAction Action,
    string Label,
    string Group,
    KeyboardShortcutGesture DefaultGesture);

public sealed record KeyboardShortcutValidation(bool IsValid, string Message)
{
    public static KeyboardShortcutValidation Valid { get; } = new(true, string.Empty);
}

public static class KeyboardShortcutCatalog
{
    public static IReadOnlyList<KeyboardShortcutDefinition> Definitions { get; } =
    [
        Define(AppShortcutAction.NewWorkspaceTab, "新建会话标签", "会话", "T", ShortcutModifiers.Control),
        Define(AppShortcutAction.CloseWorkspaceTab, "关闭当前标签", "会话", "W", ShortcutModifiers.Control),
        Define(AppShortcutAction.DisconnectAndCloseWorkspaceTab, "断开并关闭标签", "会话", "W", ShortcutModifiers.Control | ShortcutModifiers.Shift),
        Define(AppShortcutAction.SearchTerminal, "搜索终端输出", "终端", "F", ShortcutModifiers.Control),
        Define(AppShortcutAction.FocusCommandInput, "聚焦命令预输入栏", "终端", "I", ShortcutModifiers.Alt),
        Define(AppShortcutAction.SendCommandInput, "发送预输入命令", "终端", "S", ShortcutModifiers.Alt),
        Define(AppShortcutAction.OpenSettings, "打开设置", "工作站", "OemComma", ShortcutModifiers.Control),
        Define(AppShortcutAction.OpenBatchCommand, "打开批量命令", "工作站", "B", ShortcutModifiers.Control | ShortcutModifiers.Shift),
        Define(AppShortcutAction.ToggleAssetSidebar, "展开或收起服务器栏", "工作站", "L", ShortcutModifiers.Control | ShortcutModifiers.Shift),
        Define(AppShortcutAction.ToggleToolInspector, "展开或收起会话工具", "工作站", "R", ShortcutModifiers.Control | ShortcutModifiers.Shift),
        Define(AppShortcutAction.ToggleTerminalFullscreen, "终端全屏", "终端", "F11", ShortcutModifiers.None),
        Define(AppShortcutAction.SelectWorkspaceTab1, "切换到标签 1", "标签切换", "Number1", ShortcutModifiers.Control),
        Define(AppShortcutAction.SelectWorkspaceTab2, "切换到标签 2", "标签切换", "Number2", ShortcutModifiers.Control),
        Define(AppShortcutAction.SelectWorkspaceTab3, "切换到标签 3", "标签切换", "Number3", ShortcutModifiers.Control),
        Define(AppShortcutAction.SelectWorkspaceTab4, "切换到标签 4", "标签切换", "Number4", ShortcutModifiers.Control),
        Define(AppShortcutAction.SelectWorkspaceTab5, "切换到标签 5", "标签切换", "Number5", ShortcutModifiers.Control),
        Define(AppShortcutAction.SelectWorkspaceTab6, "切换到标签 6", "标签切换", "Number6", ShortcutModifiers.Control),
        Define(AppShortcutAction.SelectWorkspaceTab7, "切换到标签 7", "标签切换", "Number7", ShortcutModifiers.Control),
        Define(AppShortcutAction.SelectWorkspaceTab8, "切换到标签 8", "标签切换", "Number8", ShortcutModifiers.Control),
        Define(AppShortcutAction.SelectWorkspaceTab9, "切换到标签 9", "标签切换", "Number9", ShortcutModifiers.Control),
        Define(AppShortcutAction.SelectTerminalPane1, "切换到分屏 1", "分屏切换", "Number1", ShortcutModifiers.Alt),
        Define(AppShortcutAction.SelectTerminalPane2, "切换到分屏 2", "分屏切换", "Number2", ShortcutModifiers.Alt),
        Define(AppShortcutAction.SelectTerminalPane3, "切换到分屏 3", "分屏切换", "Number3", ShortcutModifiers.Alt),
        Define(AppShortcutAction.SelectTerminalPane4, "切换到分屏 4", "分屏切换", "Number4", ShortcutModifiers.Alt),
    ];

    public static Dictionary<AppShortcutAction, KeyboardShortcutGesture?> CreateDefaults() =>
        Definitions.ToDictionary(definition => definition.Action, definition => (KeyboardShortcutGesture?)definition.DefaultGesture);

    public static string DisplayKey(string key) => key switch
    {
        "OemComma" => ",",
        "OemPeriod" => ".",
        "OemPlus" => "+",
        "OemMinus" => "-",
        "OemQuestion" => "/",
        "OemSemicolon" => ";",
        _ when key.StartsWith("Number", StringComparison.Ordinal) => key[6..],
        _ => key,
    };

    private static KeyboardShortcutDefinition Define(
        AppShortcutAction action,
        string label,
        string group,
        string key,
        ShortcutModifiers modifiers) =>
        new(action, label, group, new KeyboardShortcutGesture(key, modifiers));
}

public static class KeyboardShortcutPolicy
{
    private static readonly HashSet<string> ModifierOnlyKeys = new(StringComparer.OrdinalIgnoreCase)
    {
        "Control", "LeftControl", "RightControl", "Shift", "LeftShift", "RightShift",
        "Menu", "LeftMenu", "RightMenu", "LeftWindows", "RightWindows",
    };

    public static KeyboardShortcutValidation ValidateAssignment(
        AppShortcutAction action,
        KeyboardShortcutGesture gesture,
        IReadOnlyDictionary<AppShortcutAction, KeyboardShortcutGesture?> assignments)
    {
        if (string.IsNullOrWhiteSpace(gesture.Key) || ModifierOnlyKeys.Contains(gesture.Key))
        {
            return Invalid("请同时按下 Ctrl 或 Alt 与一个普通按键。");
        }

        var isTerminalFullscreenFunctionKey = action == AppShortcutAction.ToggleTerminalFullscreen &&
            gesture.Modifiers == ShortcutModifiers.None &&
            string.Equals(gesture.Key, "F11", StringComparison.OrdinalIgnoreCase);
        if (!isTerminalFullscreenFunctionKey &&
            !gesture.Modifiers.HasFlag(ShortcutModifiers.Control) &&
            !gesture.Modifiers.HasFlag(ShortcutModifiers.Alt))
        {
            return Invalid("应用快捷键必须包含 Ctrl 或 Alt，普通按键和 Shift 单独使用时保留给终端输入。");
        }

        if (IsWindowsReserved(gesture))
        {
            return Invalid("该组合由 Windows 保留，OrbitTerm 不会覆盖系统快捷键。");
        }

        if (IsEditingReserved(gesture))
        {
            return Invalid("该组合保留给复制、粘贴、撤销或文本选择，不可绑定为应用操作。");
        }

        if (IsTerminalControlReserved(gesture) && !IsBuiltInDefault(gesture))
        {
            return Invalid("该 Ctrl 组合保留给远端终端。请改用 Ctrl+Shift 或 Alt 组合。");
        }

        var conflict = assignments.FirstOrDefault(pair =>
            pair.Key != action && pair.Value is not null && Equivalent(pair.Value, gesture));
        if (conflict.Value is not null)
        {
            var label = KeyboardShortcutCatalog.Definitions.First(item => item.Action == conflict.Key).Label;
            return Invalid($"与“{label}”冲突。");
        }

        return KeyboardShortcutValidation.Valid;
    }

    public static KeyboardShortcutValidation ValidateAll(
        IReadOnlyDictionary<AppShortcutAction, KeyboardShortcutGesture?> assignments)
    {
        foreach (var pair in assignments)
        {
            if (pair.Value is null) continue;
            var validation = ValidateAssignment(pair.Key, pair.Value, assignments);
            if (!validation.IsValid) return validation;
        }
        return KeyboardShortcutValidation.Valid;
    }

    private static bool IsWindowsReserved(KeyboardShortcutGesture gesture)
    {
        var alt = gesture.Modifiers.HasFlag(ShortcutModifiers.Alt);
        var control = gesture.Modifiers.HasFlag(ShortcutModifiers.Control);
        var shift = gesture.Modifiers.HasFlag(ShortcutModifiers.Shift);
        return (alt && gesture.Key is "Tab" or "F4" or "Space") ||
               (control && alt && gesture.Key == "Delete") ||
               (control && shift && gesture.Key == "Escape");
    }

    private static bool IsEditingReserved(KeyboardShortcutGesture gesture)
    {
        if (!gesture.Modifiers.HasFlag(ShortcutModifiers.Control) ||
            gesture.Modifiers.HasFlag(ShortcutModifiers.Alt))
        {
            return false;
        }
        return gesture.Key is "A" or "C" or "V" or "X" or "Y" or "Z";
    }

    private static bool IsTerminalControlReserved(KeyboardShortcutGesture gesture) =>
        gesture.Modifiers == ShortcutModifiers.Control &&
        gesture.Key.Length == 1 &&
        char.IsAsciiLetter(gesture.Key[0]);

    private static bool IsBuiltInDefault(KeyboardShortcutGesture gesture) =>
        KeyboardShortcutCatalog.Definitions.Any(definition => Equivalent(definition.DefaultGesture, gesture));

    private static bool Equivalent(KeyboardShortcutGesture left, KeyboardShortcutGesture right) =>
        left.Modifiers == right.Modifiers && string.Equals(left.Key, right.Key, StringComparison.OrdinalIgnoreCase);

    private static KeyboardShortcutValidation Invalid(string message) => new(false, message);
}
