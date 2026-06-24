#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if ! is_macos; then
  warn "Apple release gates require macOS; skipped on $(uname -s)"
  exit 0
fi

require_command cargo
require_command rustup
require_command xcodebuild
require_command xcodegen
require_command nm

export CARGO_NET_OFFLINE=true
project="$ORBIT_ROOT/OrbitTerm.xcodeproj"

section "Apple Rust static libraries"
for target in aarch64-apple-darwin aarch64-apple-ios-sim; do
  rustup target list --installed | grep -qx "$target" || \
    fail "Rust target $target is not installed; install it during CI setup"
done
(
  cd "$ORBIT_ROOT/orbit-core"
  MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --locked --target aarch64-apple-darwin
  MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --locked --release --target aarch64-apple-darwin
  IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo build --locked --target aarch64-apple-ios-sim
  IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo build --locked --release --target aarch64-apple-ios-sim
)

section "Checked FFI XCTest"
xcodebuild test -quiet -project "$project" -scheme OrbitTermCheckedFFITests \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO

section "macOS Debug and Release"
xcodebuild build -quiet -project "$project" -scheme OrbitTerm_macOS -configuration Debug \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO
xcodebuild build -quiet -project "$project" -scheme OrbitTerm_macOS -configuration Release \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO

section "iOS Simulator Debug and Release"
xcodebuild build -quiet -project "$project" -scheme OrbitTerm_iOS -configuration Debug \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
xcodebuild build -quiet -project "$project" -scheme OrbitTerm_iOS -configuration Release \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO

section "Release build settings"
release_settings="$(xcodebuild -showBuildSettings -project "$project" -scheme OrbitTerm_macOS -configuration Release 2>/dev/null)"
release_conditions="$(awk -F'= ' '/SWIFT_ACTIVE_COMPILATION_CONDITIONS/{print $2; exit}' <<<"$release_settings")"
grep -q 'ORBITTERM_PUBLIC_RELEASE' <<<"$release_conditions" || fail "Release build is missing ORBITTERM_PUBLIC_RELEASE"
if grep -q 'ORBITTERM_INTERNAL_LEGACY_NETWORK' <<<"$release_conditions"; then
  fail "Release build enables the internal legacy network condition"
fi

section "Release Swift object references"
object_root="$(awk -F'= ' '/OBJECT_FILE_DIR_normal/{print $2; exit}' <<<"$release_settings")/arm64"
[[ -d "$object_root" ]] || fail "Release Swift object directory not found: $object_root"
object_refs="$(find "$object_root" -name '*.o' -print0 | xargs -0 nm -u 2>/dev/null | awk '{print $NF}')"
if rg -q '^_orbit_(ssh_connect|test_ssh_connection|sftp_connect|request_channel|exec_command|fetch_system_stats|fetch_docker_containers|fetch_docker_stats|fetch_docker_logs|docker_action)$' <<<"$object_refs"; then
  rg '^_orbit_(ssh_connect|test_ssh_connection|sftp_connect|request_channel|exec_command|fetch_system_stats|fetch_docker_containers|fetch_docker_stats|fetch_docker_logs|docker_action)$' <<<"$object_refs" >&2
  fail "Release Swift objects reference a dangerous legacy ABI"
fi
for symbol in \
  orbit_ssh_connect_checked_v1 \
  orbit_terminal_open_checked_v1 \
  orbit_sftp_open_checked_v1 \
  orbit_monitor_snapshot_checked_v1 \
  orbit_docker_list_checked_v1 \
  orbit_docker_stats_checked_v1 \
  orbit_docker_logs_checked_v1 \
  orbit_docker_action_checked_v1 \
  orbit_exec_checked_v1; do
  grep -qx "_$symbol" <<<"$object_refs" || fail "Release Swift object does not reference checked ABI: $symbol"
done
pass "Release objects reference checked ABIs and no dangerous legacy ABI"

section "XcodeGen canonical spec"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/orbitterm-xcodegen-gate.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
xcodegen generate --quiet --spec "$ORBIT_ROOT/project.yml" --project "$tmp_dir" --project-root "$ORBIT_ROOT"
generated_project="$tmp_dir/OrbitTerm.xcodeproj"
[[ -f "$generated_project/project.pbxproj" ]] || fail "XcodeGen did not produce a project"
rg -q 'ORBITTERM_PUBLIC_RELEASE' "$generated_project/project.pbxproj" || fail "generated project is missing the public Release condition"
rg -q 'OrbitTermCheckedFFITests' "$generated_project/project.pbxproj" || fail "generated project is missing the checked FFI test target"
rg -q 'ORBITTERM_PUBLIC_RELEASE' "$project/project.pbxproj" || fail "checked-in project is missing the public Release condition"
rg -q 'OrbitTermCheckedFFITests' "$project/project.pbxproj" || fail "checked-in project is missing the checked FFI test target"
[[ -f "$generated_project/xcshareddata/xcschemes/OrbitTermCheckedFFITests.xcscheme" ]] || \
  fail "generated project does not expose the checked FFI test scheme"
xcodebuild test -quiet -project "$generated_project" -scheme OrbitTermCheckedFFITests \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO
pass "project.yml and checked-in project contain the same release-security targets and flags"

section "Whitespace validation"
git -C "$ORBIT_ROOT" diff --check

pass "Apple release gates"
