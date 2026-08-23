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
require_command codesign
require_command cargo
require_command rustup

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

section "Run signed macOS UI smoke"
xcodebuild test -project "$project" -scheme OrbitTermmacOSUITests \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data"

app_path="$derived_data/Build/Products/Debug/OrbitTerm.app"
[[ -d "$app_path" ]] || fail "signed UI smoke did not produce OrbitTerm.app"
codesign --verify --deep --strict --verbose=2 "$app_path"
signature_info="$(codesign -dvv "$app_path" 2>&1)"
grep -q '^Authority=' <<<"$signature_info" || \
  fail "signed UI smoke produced an ad-hoc or unsigned app; configure the release-candidate signing identity"
pass "signed macOS UI smoke completed and produced a valid signed app"
