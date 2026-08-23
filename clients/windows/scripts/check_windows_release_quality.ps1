param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

function Pass([string]$Message) {
    Write-Host "[PASS] $Message"
}

function Read-Json([string]$Path) {
    if (!(Test-Path $Path)) {
        Fail "Required JSON file missing: $Path"
    }

    return Get-Content $Path -Raw | ConvertFrom-Json
}

function Assert-Equal([string]$Name, [string]$Actual, [string]$Expected) {
    if ($Actual -ne $Expected) {
        Fail "$Name must be '$Expected'. Actual: '$Actual'."
    }
}

$quality = Read-Json (Join-Path $Root "release\release-quality.json")
$xamlPath = Join-Path $Root "src\OrbitTerm.App\MainWindow.xaml"
if (!(Test-Path $xamlPath)) {
    Fail "MainWindow.xaml is required for release quality checks."
}

$xaml = Get-Content $xamlPath -Raw
$codeBehindPath = Join-Path $Root "src\OrbitTerm.App\MainWindow.xaml.cs"
if (!(Test-Path $codeBehindPath)) {
    Fail "MainWindow.xaml.cs is required for release quality checks."
}

$codeBehind = Get-Content $codeBehindPath -Raw
Assert-Equal "schema_version" ([string]$quality.schema_version) "1"

if ($quality.minimum_window_width -lt 960 -or $quality.minimum_window_height -lt 640) {
    Fail "Release quality metadata must keep a practical minimum window size."
}

if ($xaml -match "^\s+MinWidth=" -or $xaml -match "^\s+MinHeight=") {
    Fail "WinUI Window root must not use unsupported MinWidth/MinHeight attributes."
}

if ($codeBehind -notmatch "MinimumWindowWidth\s*=\s*$($quality.minimum_window_width)\s*;") {
    Fail "MainWindow minimum width constant must match release quality metadata."
}

if ($codeBehind -notmatch "MinimumWindowHeight\s*=\s*$($quality.minimum_window_height)\s*;") {
    Fail "MainWindow minimum height constant must match release quality metadata."
}

if ($codeBehind -notmatch "WindowMessageGetMinMaxInfo" -or
    $codeBehind -notmatch "MinimumTrackingSize\s*=\s*new NativePoint") {
    Fail "MainWindow must enforce the release quality minimum through WM_GETMINMAXINFO."
}

if ($quality.minimum_text_font_size -lt 12) {
    Fail "Release quality metadata must not allow text below 12px."
}

$fontSizes = [regex]::Matches($xaml, 'FontSize="([0-9]+)"')
foreach ($fontSize in $fontSizes) {
    if ([int]$fontSize.Groups[1].Value -lt [int]$quality.minimum_text_font_size) {
        Fail "XAML contains text below the minimum font size: $($fontSize.Value)"
    }
}

foreach ($command in @("PreviousCommandHistoryCommand", "NextCommandHistoryCommand")) {
    $pattern = "Command=`"{Binding $command}`""
    $index = $xaml.IndexOf($pattern, [System.StringComparison]::Ordinal)
    if ($index -lt 0) {
        Fail "Keyboard history command missing from XAML: $command"
    }

    $window = $xaml.Substring($index, [Math]::Min(260, $xaml.Length - $index))
    if ($window -notmatch "AutomationProperties\.Name=") {
        Fail "Icon-only command must define AutomationProperties.Name: $command"
    }
}

foreach ($requiredControl in @(
    "NativeTerminalView",
    "TerminalPreInputBox",
    "SftpEntriesList",
    "ActiveSftpTransfersTab",
    "CompletedSftpTransfersTab"
)) {
    $controlPattern = "<[^>]*x:Name=`"$([regex]::Escape($requiredControl))`"[^>]*>"
    $controlMarkup = [regex]::Match($xaml, $controlPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline).Value
    if ([string]::IsNullOrWhiteSpace($controlMarkup) -or
        $controlMarkup -notmatch "AutomationProperties\.Name=") {
        Fail "Required accessibility name missing from control: $requiredControl"
    }
}

if ($xaml -match "<Image\b") {
    # The only approved raster is the packaged 44px brand mark rendered inside
    # the fixed 22-DIP title-bar slot (2x source density). Any content image or
    # unbounded raster still fails this gate.
    $images = [regex]::Matches($xaml, '<Image\b[^>]*>')
    if ($images.Count -ne 1 -or
        $images[0].Value -notmatch 'Source="ms-appx:///Assets/Square44x44Logo\.png"' -or
        $xaml -notmatch '<Border Width="22"\s+Height="22"') {
        Fail "Release UI contains an unreviewed raster Image element."
    }
}

if ($quality.requires_keyboard_access -ne $true -or $quality.requires_accessible_names -ne $true) {
    Fail "Release quality metadata must require keyboard access and accessible names."
}

if ($quality.requires_high_dpi_safe_assets -ne $true) {
    Fail "Release quality metadata must require high-DPI-safe assets."
}

if ($quality.localization.default_culture -notmatch "^[a-z]{2}-[A-Z]{2}$") {
    Fail "Release quality metadata must define a valid default culture."
}

if ($quality.localization.supported_cultures.Count -lt 1 -or
    $quality.localization.supported_cultures -notcontains $quality.localization.default_culture) {
    Fail "Release quality metadata must include the default culture in supported cultures."
}

if ($quality.localization.external_distribution_requires_string_resources -ne $true) {
    Fail "External distribution must require reviewed string resources."
}

Pass "Windows release quality smoke checks"
