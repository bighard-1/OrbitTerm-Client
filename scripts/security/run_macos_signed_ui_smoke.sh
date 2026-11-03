#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# This lane is deliberately opt-in. XCUITest needs a signed host application
# to attach to the hardened macOS process, while ordinary CI intentionally
# builds unsigned artifacts. A release-candidate runner enables this script
# only after its signing identity and provisioning profile are installed.
if [[ "${ORBITTERM_RUN_SIGNED_MACOS_UI_SMOKE:-0}" != "1" ]]; then
  warn "signed macOS UI smoke skipped; set ORBITTERM_RUN_SIGNED_MACOS_UI_SMOKE=1 on a provisioned release-candidate runner"
  exit 0
fi

if ! is_macos; then
  fail "signed macOS UI smoke requires macOS"
fi

require_command xcodebuild
require_command xcodegen
require_command xcrun
require_command codesign
require_command plutil
require_command python3
require_command pgrep
require_command cargo
require_command rustup

# The fixture launches the production bundle identifier. It may only run in
# a clean, dedicated macOS user account, never alongside an installed client
# or its existing data. Do not erase user data to make this preflight pass.
[[ "${ORBITTERM_SIGNED_UI_DEDICATED_RUNNER:-0}" == "1" ]] || \
  fail "signed macOS UI smoke requires an explicitly designated clean runner"
if pgrep -x OrbitTerm >/dev/null || \
  [[ -e /Applications/OrbitTerm.app || -e "$HOME/Applications/OrbitTerm.app" || \
     -e "$HOME/Desktop/OrbitTerm.app" || \
     -e "$HOME/Library/Application Support/OrbitTerm" || \
     -e "$HOME/Library/Containers/com.orbitterm.app" || \
     -e "$HOME/Library/Preferences/com.orbitterm.app.plist" ]]; then
  fail "signed macOS UI smoke requires a dedicated clean runner; existing OrbitTerm app or data detected"
fi

project="$ORBIT_ROOT/OrbitTerm.xcodeproj"
derived_data="$(mktemp -d "${TMPDIR:-/tmp}/orbitterm-macos-signed-ui-smoke.XXXXXX")"
trap 'rm -rf "$derived_data"' EXIT

section "Build signed-lane Rust dependency"
rustup target list --installed | grep -qx 'aarch64-apple-darwin' || \
  fail "missing aarch64-apple-darwin Rust target on the signed smoke runner"
(
  cd "$ORBIT_ROOT/orbit-core"
  MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --locked --target aarch64-apple-darwin
)

section "Generate signed macOS UI test project"
xcodegen generate --quiet --spec "$ORBIT_ROOT/project.yml" --project "$ORBIT_ROOT"

section "Build and verify signed macOS UI host"
xcodebuild build-for-testing -project "$project" -scheme OrbitTermmacOSUITests \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" CODE_SIGNING_ALLOWED=YES

app_path="$derived_data/Build/Products/Debug/OrbitTerm.app"
[[ -d "$app_path" ]] || fail "signed UI smoke did not produce OrbitTerm.app"
codesign --verify --deep --strict --verbose=2 "$app_path"
signature_info="$(codesign -dvv "$app_path" 2>&1)"
grep -q '^Authority=' <<<"$signature_info" || \
  fail "signed UI smoke produced an ad-hoc or unsigned app; configure the release-candidate signing identity"
team_id="${ORBITTERM_APPLE_TEAM_ID:-BYZK354JK4}"
grep -q "^TeamIdentifier=$team_id$" <<<"$signature_info" || \
  fail "signed UI smoke app has the wrong signing team"
bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$app_path/Contents/Info.plist")"
[[ "$bundle_id" == com.orbitterm.app ]] || fail "signed UI smoke app has the wrong bundle identifier"

section "Run signed macOS UI smoke"
result_bundle="$derived_data/macos-ui-tests.xcresult"
xcodebuild test-without-building -project "$project" -scheme OrbitTermmacOSUITests \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived_data" \
  -parallel-testing-enabled NO -resultBundlePath "$result_bundle"
ui_count="$(xcrun xcresulttool get test-results summary --path "$result_bundle" | python3 -c '
import json
import sys

summary = json.load(sys.stdin)
total = summary.get("totalTestCount", 0)
passed = summary.get("passedTests", 0)
failed = summary.get("failedTests", 0)
skipped = summary.get("skippedTests", 0)
if summary.get("result") != "Passed" or total < 5 or passed != total or failed != 0 or skipped != 0:
    print(f"macOS UI result incomplete: total={total}, passed={passed}, failed={failed}, skipped={skipped}", file=sys.stderr)
    sys.exit(1)
print(f"{passed}/{total}")
')" || fail "signed macOS UI smoke result bundle is incomplete"
pass "signed macOS UI smoke executed: $ui_count, no failures or skips"
