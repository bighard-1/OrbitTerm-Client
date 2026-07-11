#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/src"

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  exit 1
}

pass() {
  printf '[PASS] %s\n' "$1"
}

[[ -d "$SRC" ]] || fail "Windows source directory not found: $SRC"

for symbol in \
  orbit_test_ssh_connection \
  orbit_ssh_connect \
  orbit_sftp_connect \
  orbit_request_channel \
  orbit_exec_command \
  orbit_fetch_system_stats \
  orbit_fetch_docker_containers \
  orbit_fetch_docker_stats \
  orbit_fetch_docker_logs \
  orbit_docker_action; do
  if find "$SRC" -type f \( -name '*.cs' -o -name '*.xaml' -o -name '*.csproj' \) \
      ! -path '*/bin/*' ! -path '*/obj/*' \
      ! -name 'ForbiddenLegacyAbi.cs' -print0 |
      xargs -0 rg -n "\\b${symbol}\\b" >/tmp/orbitterm-windows-symbol-scan.txt 2>/dev/null; then
    cat /tmp/orbitterm-windows-symbol-scan.txt >&2
    fail "Forbidden legacy ABI symbol appears in Windows production source: $symbol"
  fi
done
pass "Production Windows source avoids forbidden legacy ABI symbols"

if find "$SRC/OrbitTerm.App" -type f \( -name '*.cs' -o -name '*.xaml' \) \
    ! -path '*/bin/*' ! -path '*/obj/*' -print0 |
    xargs -0 rg -n 'NativeMethods' >/tmp/orbitterm-windows-ui-native-scan.txt 2>/dev/null; then
  cat /tmp/orbitterm-windows-ui-native-scan.txt >&2
  fail "UI layer must not call NativeMethods directly"
fi
pass "UI layer does not call raw native methods"

python3 - "$ROOT" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
texts = [
    (root / "src/OrbitTerm.App/MainWindow.xaml.cs").read_text(),
    (root / "src/OrbitTerm.App/MainWindow.xaml").read_text(),
    (root / "src/OrbitTerm.Presentation/MainWindowViewModel.cs").read_text(),
    (root / "src/OrbitTerm.NativeBridge/CheckedFfiKind.cs").read_text(),
]
for marker in (
    "CopySftpPreviewClick",
    "SftpPathTextBoxKeyDown",
    "SftpEntriesDoubleTapped",
    "PrepareSftpPreviewCopy",
    "HasSftpPreview",
    "DownloadSelectedSftpEntryClick",
    "DownloadSftpFile",
    "SftpDownloadCompleted",
    "CreateSftpDirectory",
    "CreateSftpFile",
    "RenameSftpEntry",
    "RemoveSelectedSftpEntryConfirmedAsync",
    "ChangeSelectedSftpPermissionsConfirmedAsync",
    "ChangeSftpPermissions",
    "WriteSftpTextFile",
    "SaveSftpPreviewClick",
    "CanSaveSftpPreview",
    "SftpMutationCompleted",
    "ContentDialogButton.Close",
):
    if not any(marker in text for text in texts):
        raise SystemExit(f"SFTP browse interaction contract is missing: {marker}")
PY
pass "SFTP browse interaction contract is present"

if find "$SRC" -type f \( -name '*.cs' -o -name '*.xaml' -o -name '*.csproj' \) \
    ! -path '*/bin/*' ! -path '*/obj/*' -print0 |
    xargs -0 rg -n 'OK:|ERR:|Trust All|accept-anyway|accept anyway|仍然接受|全部信任' >/tmp/orbitterm-windows-bypass-scan.txt 2>/dev/null; then
  cat /tmp/orbitterm-windows-bypass-scan.txt >&2
  fail "Checked protocol or Host Key bypass forbidden text appears in Windows source"
fi
pass "Checked protocol and Host Key bypass UX scans passed"

for project in \
  OrbitTerm.App \
  OrbitTerm.Application \
  OrbitTerm.Presentation \
  OrbitTerm.Platform.Windows \
  OrbitTerm.NativeBridge \
  OrbitTerm.Terminal; do
  [[ -f "$SRC/$project/$project.csproj" ]] || fail "Required project missing: $project"
done
pass "Required Windows projects are present"

for script in \
  check_windows_static.ps1 \
  check_windows_toolchain.ps1 \
  build_windows_core.ps1 \
  check_windows_host.ps1 \
  check_windows_release_candidate.ps1 \
  check_windows_update_channel.ps1 \
  check_windows_release_quality.ps1 \
  check_windows_security_evidence.ps1 \
  check_windows_release_readiness.ps1 \
  build_windows_signed_package.ps1 \
  build_windows_portable.ps1 \
  run_windows_personal_test.ps1 \
  install_windows_dependencies.ps1; do
  [[ -f "$ROOT/scripts/$script" ]] || fail "Required Windows validation script missing: $script"
done
pass "Required Windows validation scripts are present"

python3 - "$ROOT" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
script = root / "scripts/run_windows_personal_test.ps1"
text = script.read_text()
for marker in (
    "Set-StrictMode -Version Latest",
    "Personal Windows app launch requires a Windows host.",
    "SkipStaticGate",
    "check_windows_static.ps1",
    "Windows static gate",
    "& $Dotnet build",
    "OrbitTerm.App.csproj",
    "OrbitTerm.App.exe",
    "Start-Process",
):
    if marker not in text:
        raise SystemExit(f"Personal Windows test launcher is missing required behavior marker: {marker}")
PY
pass "Personal Windows test launcher contract is present"

python3 - "$ROOT" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
guide = root / "docs/PERSONAL-TESTING.md"
if not guide.is_file():
    raise SystemExit(f"Personal Windows testing guide missing: {guide}")

text = guide.read_text()
for marker in (
    "run_windows_personal_test.ps1",
    "-NoLaunch",
    "check_windows_toolchain.ps1",
    "personal testing",
    "not a commercial distribution",
):
    if marker not in text:
        raise SystemExit(f"Personal Windows testing guide is missing required guidance marker: {marker}")
PY
pass "Personal Windows testing guide contract is present"

python3 - "$ROOT" <<'PY'
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(sys.argv[1])
channel = json.loads((root / "release/update-channel.json").read_text())
manifest = ET.parse(root / "src/OrbitTerm.App/Package.appxmanifest").getroot()
ns = {"m": "http://schemas.microsoft.com/appx/manifest/foundation/windows10"}
identity = manifest.find("m:Identity", ns)
target = manifest.find("m:Dependencies/m:TargetDeviceFamily", ns)
if identity is None or target is None:
    raise SystemExit("Package manifest identity or target device family is missing")

def require(name, actual, expected):
    if actual != expected:
        raise SystemExit(f"{name} must be {expected!r}. Actual: {actual!r}")

def require_version(name, value):
    if not re.fullmatch(r"\d+\.\d+\.\d+\.\d+", value):
        raise SystemExit(f"{name} must use four-part numeric version format: {value!r}")

require("schema_version", str(channel.get("schema_version")), "1")
require("product", channel.get("product"), "OrbitTerm")
require("channel", channel.get("channel"), "stable")
require("package_identity", channel.get("package_identity"), identity.attrib.get("Name"))
require("publisher", channel.get("publisher"), identity.attrib.get("Publisher"))
require("version", channel.get("version"), identity.attrib.get("Version"))
require("minimum_windows_version", channel.get("minimum_windows_version"), target.attrib.get("MinVersion"))
require("update_transport", channel.get("update_transport"), "appinstaller")
require_version("version", channel.get("version", ""))
require_version("minimum_windows_version", channel.get("minimum_windows_version", ""))
if channel.get("requires_signed_package") is not True:
    raise SystemExit("Update channel must require signed packages")
if channel.get("requires_https_update_uri") is not True:
    raise SystemExit("Update channel must require HTTPS update URIs")
rollout = channel.get("rollout") or {}
if channel.get("external_distribution_enabled") is True:
    for key in ("appinstaller_uri", "package_uri"):
        value = channel.get(key, "")
        if not value.startswith("https://"):
            raise SystemExit(f"Enabled external distribution requires HTTPS {key}")
    percentage = rollout.get("percentage")
    if not isinstance(percentage, int) or percentage < 1 or percentage > 100:
        raise SystemExit("Enabled external distribution rollout percentage must be 1..100")
else:
    if channel.get("appinstaller_uri") or channel.get("package_uri"):
        raise SystemExit("Disabled external distribution must not define update URIs")
    if rollout.get("mode") != "manual" or rollout.get("percentage") != 0:
        raise SystemExit("Disabled external distribution rollout must be manual 0 percent")
PY
pass "Windows update channel metadata is pinned"

python3 - "$ROOT" <<'PY'
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
quality = json.loads((root / "release/release-quality.json").read_text())
xaml = (root / "src/OrbitTerm.App/MainWindow.xaml").read_text()
code_behind = (root / "src/OrbitTerm.App/MainWindow.xaml.cs").read_text()
window_open = xaml.split(">", 1)[0]

def require(condition, message):
    if not condition:
        raise SystemExit(message)

require(str(quality.get("schema_version")) == "1", "schema_version must be 1")
require(quality.get("minimum_window_width", 0) >= 960, "minimum_window_width is too small")
require(quality.get("minimum_window_height", 0) >= 640, "minimum_window_height is too small")
require("MinWidth=" not in window_open and "MinHeight=" not in window_open, "WinUI Window root must not use unsupported MinWidth/MinHeight attributes")
require(re.search(rf"MinimumWindowWidth\s*=\s*{quality['minimum_window_width']}\s*;", code_behind), "MainWindow minimum width constant missing")
require(re.search(rf"MinimumWindowHeight\s*=\s*{quality['minimum_window_height']}\s*;", code_behind), "MainWindow minimum height constant missing")
require("AppWindow.Resize(new SizeInt32(MinimumWindowWidth, MinimumWindowHeight))" in code_behind, "MainWindow AppWindow resize policy missing")
minimum_font = int(quality.get("minimum_text_font_size", 0))
require(minimum_font >= 12, "minimum_text_font_size is too small")
for value in re.findall(r'FontSize="([0-9]+)"', xaml):
    require(int(value) >= minimum_font, f"FontSize below minimum: {value}")
for command in ("PreviousCommandHistoryCommand", "NextCommandHistoryCommand"):
    index = xaml.find(f'Command="{{Binding {command}}}"')
    require(index >= 0, f"Keyboard history command missing: {command}")
    require("AutomationProperties.Name=" in xaml[index:index + 260], f"Accessible name missing for {command}")
for name in (
    "Server assets",
    "SFTP directory entries",
    "SFTP preview text",
    "Previous command",
    "Next command",
):
    require(f'AutomationProperties.Name="{name}"' in xaml, f"Accessible name missing: {name}")
require("<Image" not in xaml, "High-DPI smoke disallows unmanaged Image elements")
require(quality.get("requires_keyboard_access") is True, "keyboard access requirement missing")
require(quality.get("requires_accessible_names") is True, "accessible name requirement missing")
require(quality.get("requires_high_dpi_safe_assets") is True, "high-DPI requirement missing")
localization = quality.get("localization") or {}
require(localization.get("default_culture") == "en-US", "default culture must be en-US")
require("en-US" in localization.get("supported_cultures", []), "supported cultures must include en-US")
require(localization.get("external_distribution_requires_string_resources") is True, "external distribution must require string resources")
PY
pass "Windows release quality smoke checks"

python3 - "$ROOT" <<'PY'
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(sys.argv[1])
bundle = json.loads((root / "release/security-evidence.json").read_text())
manifest = ET.parse(root / "src/OrbitTerm.App/Package.appxmanifest").getroot()
ns = {"m": "http://schemas.microsoft.com/appx/manifest/foundation/windows10"}
identity = manifest.find("m:Identity", ns)

def require(condition, message):
    if not condition:
        raise SystemExit(message)

require(str(bundle.get("schema_version")) == "1", "security-evidence schema_version must be 1")
require(bundle.get("product") == "OrbitTerm", "security-evidence product must be OrbitTerm")
require(bundle.get("package_identity") == "OrbitTerm.Client", "security-evidence package_identity must be OrbitTerm.Client")
require(re.fullmatch(r"\d+\.\d+\.\d+\.\d+", bundle.get("version", "")), "security-evidence version must be four-part numeric")
require(identity is not None, "Package manifest identity is missing")
require(identity.attrib.get("Name") == bundle["package_identity"], "security-evidence package_identity must match manifest")
require(identity.attrib.get("Version") == bundle["version"], "security-evidence version must match manifest")

for document in bundle.get("evidence_documents", []):
    path = root / document
    require(path.is_file(), f"Evidence document missing: {document}")
    text = path.read_text()
    require(text.strip(), f"Evidence document is empty: {document}")
    if document.startswith("docs/PHASE-3"):
        require("- Pending." not in text, f"Phase 3 evidence document is still pending: {document}")

for artifact in bundle.get("release_artifacts", []):
    require((root / artifact).is_file(), f"Release artifact missing: {artifact}")

for script in bundle.get("validation_scripts", []):
    require((root / script).is_file(), f"Validation script missing: {script}")

required_gates = {
    "checked-ffi-only",
    "host-key-verified-sessions",
    "windows-secure-credential-storage",
    "release-candidate-gate",
    "msix-package-identity",
    "signed-package-contract",
    "update-channel-contract",
    "redacted-diagnostics",
    "release-quality-smoke",
    "security-evidence-bundle",
    "full-winui-host-build",
}
actual_gates = set(bundle.get("required_release_gates", []))
missing = sorted(required_gates - actual_gates)
require(not missing, f"Required release gates missing: {missing}")
PY
pass "Windows security evidence bundle is complete"

python3 - "$ROOT" <<'PY'
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(sys.argv[1])
readiness = json.loads((root / "release/release-readiness.json").read_text())
channel = json.loads((root / "release/update-channel.json").read_text())
evidence = json.loads((root / "release/security-evidence.json").read_text())
manifest = ET.parse(root / "src/OrbitTerm.App/Package.appxmanifest").getroot()
ns = {"m": "http://schemas.microsoft.com/appx/manifest/foundation/windows10"}
identity = manifest.find("m:Identity", ns)

def require(condition, message):
    if not condition:
        raise SystemExit(message)

def require_equal(name, actual, expected):
    require(actual == expected, f"{name} must be {expected!r}. Actual: {actual!r}")

require(identity is not None, "Package manifest identity is missing")
require_equal("release-readiness schema_version", str(readiness.get("schema_version")), "1")
require_equal("release-readiness product", readiness.get("product"), "OrbitTerm")
require_equal("release-readiness package_identity", readiness.get("package_identity"), identity.attrib.get("Name"))
require_equal("release-readiness version", readiness.get("version"), identity.attrib.get("Version"))
require(re.fullmatch(r"\d+\.\d+\.\d+\.\d+", readiness.get("version", "")), "release-readiness version must be four-part numeric")
require_equal("release-readiness package_identity/update-channel package_identity", readiness.get("package_identity"), channel.get("package_identity"))
require_equal("release-readiness version/update-channel version", readiness.get("version"), channel.get("version"))
require_equal("release-readiness package_identity/security-evidence package_identity", readiness.get("package_identity"), evidence.get("package_identity"))
require_equal("release-readiness version/security-evidence version", readiness.get("version"), evidence.get("version"))
require(readiness.get("internal_release_candidate_ready") is True, "internal_release_candidate_ready must be true")
require(channel.get("requires_signed_package") is True, "update channel must require signed packages")
require(channel.get("requires_https_update_uri") is True, "update channel must require HTTPS update URIs")

required_gates = {
    "windows-toolchain",
    "windows-host-plan-validation",
    "checked-ffi-only",
    "host-key-verified-sessions",
    "windows-secure-credential-storage",
    "release-candidate-gate",
    "msix-package-identity",
    "signed-package-contract",
    "update-channel-contract",
    "redacted-diagnostics",
    "release-quality-smoke",
    "security-evidence-bundle",
    "full-winui-host-build",
}
missing = sorted(required_gates - set(readiness.get("required_gates", [])))
require(not missing, f"release-readiness required gates missing: {missing}")

if readiness.get("external_distribution_enabled") is True:
    require(readiness.get("readiness_profile") == "external-commercial-release", "external distribution requires external-commercial-release profile")
    require(channel.get("external_distribution_enabled") is True, "external readiness requires update channel external distribution")
    require(not readiness.get("external_distribution_blockers"), "external distribution blockers must be empty")
    for field in ("appinstaller_uri", "package_uri"):
        require(str(channel.get(field, "")).startswith("https://"), f"external distribution requires HTTPS {field}")
else:
    require_equal("release-readiness profile", readiness.get("readiness_profile"), "internal-release-candidate")
    require(channel.get("external_distribution_enabled") is False, "internal release candidate requires disabled update channel distribution")
    blockers = readiness.get("external_distribution_blockers") or []
    require(len(blockers) >= 3, "internal release candidate must list concrete external distribution blockers")
    require(not channel.get("appinstaller_uri") and not channel.get("package_uri"), "internal release candidate must not define production update URIs")
    rollout = channel.get("rollout") or {}
    require(rollout.get("mode") == "manual" and rollout.get("percentage") == 0, "internal release candidate rollout must be manual 0 percent")
PY
pass "Windows release readiness gate"

pass "Windows static checks"
