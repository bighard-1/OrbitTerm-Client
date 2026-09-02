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
require_command strings

export CARGO_NET_OFFLINE=true
project="$ORBIT_ROOT/OrbitTerm.xcodeproj"
derived_data="$(mktemp -d "${TMPDIR:-/tmp}/orbitterm-apple-release-gates.XXXXXX")"
trap 'rm -rf "$derived_data"' EXIT

section "Declared Apple platform support"
mac_settings="$(xcodebuild -showBuildSettings -project "$project" -scheme OrbitTerm_macOS -configuration Release 2>/dev/null)"
ios_device_settings="$(xcodebuild -showBuildSettings -project "$project" -scheme OrbitTerm_iOS -configuration Release -destination 'generic/platform=iOS' 2>/dev/null)"
grep -q '^    ARCHS = arm64$' <<<"$mac_settings" || fail "macOS support matrix must remain arm64-only"
grep -q '^    ARCHS = arm64$' <<<"$ios_device_settings" || fail "iPhoneOS support matrix must remain arm64-only"
rg -q 'ARCHS\[sdk=macosx\*\]: arm64' "$ORBIT_ROOT/project.yml" || fail "project.yml must explicitly declare macOS arm64-only support"
rg -q 'ARCHS\[sdk=iphoneos\*\]: arm64' "$ORBIT_ROOT/project.yml" || fail "project.yml must explicitly declare iPhoneOS arm64 support"
pass "macOS arm64 and iPhoneOS arm64 support matrix verified; Intel macOS is intentionally unsupported"

"$ORBIT_ROOT/scripts/security/check_platform_behavior_alignment_matrix.sh"

section "Apple Rust static libraries"
for target in aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim; do
  rustup target list --installed | grep -qx "$target" || \
    fail "Rust target $target is not installed; install it during CI setup"
done
(
  cd "$ORBIT_ROOT/orbit-core"
  MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --locked --target aarch64-apple-darwin
  MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --locked --release --target aarch64-apple-darwin
  IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo build --locked --target aarch64-apple-ios
  IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo build --locked --release --target aarch64-apple-ios
  IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo build --locked --target aarch64-apple-ios-sim
  IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo build --locked --release --target aarch64-apple-ios-sim
)

section "Apple privacy, entitlement, and build provenance inputs"
privacy_manifest="$ORBIT_ROOT/OrbitTerm/App/PrivacyInfo.xcprivacy"
entitlements="$ORBIT_ROOT/OrbitTerm/OrbitTerm.entitlements"
[[ -f "$privacy_manifest" ]] || fail "missing Apple privacy manifest"
[[ -f "$entitlements" ]] || fail "missing Apple entitlements"
plutil -lint "$privacy_manifest" >/dev/null || fail "invalid Apple privacy manifest"
plutil -lint "$entitlements" >/dev/null || fail "invalid Apple entitlements"
rg -q 'NSPrivacyAccessedAPICategoryUserDefaults' "$privacy_manifest" || fail "privacy manifest does not declare UserDefaults access"
rg -q '<key>keychain-access-groups</key>' "$entitlements" || fail "missing reviewed Keychain entitlement"
if rg -n 'com[.]apple[.]security[.](network[.]server|automation[.]apple-events)' "$entitlements"; then
  fail "unreviewed privileged server or automation entitlement found"
fi
evidence_dir="$(mktemp -d "${TMPDIR:-/tmp}/orbitterm-apple-evidence.XXXXXX")"
"$ORBIT_ROOT/scripts/security/collect_apple_build_evidence.sh" "$evidence_dir" >/dev/null
[[ -s "$evidence_dir/build-evidence.properties" ]] || fail "Apple build evidence was not generated"
rm -rf "$evidence_dir"
pass "privacy manifest, entitlements, locked dependencies, and Rust provenance inputs verified"

section "Public Release UI exclusions"
auth_view="$ORBIT_ROOT/OrbitTerm/Features/Auth/AuthView.swift"
settings_view="$ORBIT_ROOT/OrbitTerm/Features/Home/SettingsView.swift"
rg -U -q '#if ORBITTERM_PUBLIC_RELEASE\nprivate struct DevelopmentEndpointControls: ViewModifier \{[[:space:][:print:]]{0,400}func body\(content: Content\) -> some View \{ content \}' "$auth_view" || \
  fail "public Release does not compile the development endpoint control to a no-op"
rg -U -q '#if os\(macOS\)\n[[:space:]]*@AppStorage\("orbitterm[.]monitor[.]history[.]range"\)' "$settings_view" || \
  fail "mobile build still owns the workstation-only monitor range setting"
pass "development endpoint UI and inert mobile monitor range are excluded from public Release"

# XCTest runs with a file-system sandbox and cannot load linked test
# dependencies directly from the repository-local audited toolchain path.
# Stage the exact reviewed dylibs inside each isolated build-products rpath;
# do not weaken the sandbox or fall back to a machine-global FreeRDP install.
stage_checked_test_runtime() {
  local products_dir="$1"
  mkdir -p "$products_dir"
  local runtime_dir
  for runtime_dir in \
    "$ORBIT_ROOT/.tooling/freerdp-macos/install/freerdp/lib" \
    "$ORBIT_ROOT/.tooling/freerdp-macos/install/openssl/lib"; do
    while IFS= read -r runtime; do
      cp -L "$runtime" "$products_dir/$(basename "$runtime")"
    done < <(find "$runtime_dir" -maxdepth 1 \( -type f -o -type l \) -name '*.dylib*' | sort)
  done
}

section "Checked FFI XCTest"
stage_checked_test_runtime "$derived_data/Build/Products/Debug"
xcodebuild test -quiet -project "$project" -scheme OrbitTermCheckedFFITests \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived_data" CODE_SIGNING_ALLOWED=NO

section "Lifecycle ownership regressions"
# These targeted tests are intentionally named in the gate so a lock, sign-out,
# account switch, or closed-window late callback cannot silently lose CI
# coverage when the broader test bundle changes.
xcodebuild test -quiet -project "$project" -scheme OrbitTermCheckedFFITests \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived_data" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OrbitTermCheckedFFITests/ApplicationOperationLifecyclePolicyTests \
  -only-testing:OrbitTermCheckedFFITests/OperationOwnerTests

section "Bounded resource stress regressions"
# These deterministic fixtures exercise the same terminal, Docker log,
# monitor-history, SFTP-admission, and sync-admission primitives used by the
# app. They use synthetic payloads only and need no live SSH service.
xcodebuild test -quiet -project "$project" -scheme OrbitTermCheckedFFITests \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived_data" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OrbitTermCheckedFFITests/OperationResourceBudgetTests \
  -only-testing:OrbitTermCheckedFFITests/OperationResourceBudgetStressTests

section "Native HTTP fault regressions"
# Keep timeout, connection interruption, truncated/malformed success payloads,
# cancellation, and idempotency-header stability in the mandatory Apple gate.
xcodebuild test -quiet -project "$project" -scheme OrbitTermCheckedFFITests \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived_data" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OrbitTermCheckedFFITests/NetworkServiceFaultInjectionTests

section "Real-device performance evidence contract"
# Ordinary source CI cannot manufacture real-device performance evidence. A
# signed release-candidate lane sets both variables and therefore fails closed
# when any required scenario is absent or exceeds its published SLO.
if [[ "${ORBITTERM_REQUIRE_DEVICE_PERFORMANCE_EVIDENCE:-0}" == "1" ]]; then
  evidence_dir="${ORBITTERM_DEVICE_PERFORMANCE_EVIDENCE_DIR:-}"
  [[ -n "$evidence_dir" ]] || fail "release lane requires ORBITTERM_DEVICE_PERFORMANCE_EVIDENCE_DIR"
  "$ORBIT_ROOT/scripts/security/check_apple_device_performance_evidence.sh" "$evidence_dir"
  pass "real-device performance SLO evidence verified"
else
  warn "real-device performance evidence is required only in the signed release-candidate lane"
fi

section "iOS Simulator UI root lifecycle"
simulator_id="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ { print $2; exit }')"
[[ -n "$simulator_id" ]] || fail "no available iPhone simulator for UI lifecycle tests"
xcrun simctl boot "$simulator_id" 2>/dev/null || true
xcrun simctl bootstatus "$simulator_id" -b
# Xcode 26.6 can compile an unsigned UI-test bundle but cannot reliably launch
# its test host (the runner reports missing debugger metadata and app roots are
# never exposed). Simulator signing is ephemeral and uses no distribution
# identity, so keep the source-build lanes unsigned while allowing Xcode's
# default ad-hoc signing for this executable UI lifecycle contract.
xcodebuild test -quiet -project "$project" -scheme OrbitTermiOSUITests \
  -destination "platform=iOS Simulator,id=$simulator_id" -derivedDataPath "$derived_data"

section "macOS UI target compile contract"
# A macOS XCUITest runner needs a locally provisioned signing identity in order
# to attach to the hardened app. CI therefore compiles the same UI target here;
# the behavior contract itself runs above as unsigned lifecycle tests. A signed
# release-candidate lane may execute OrbitTermmacOSUITests separately.
xcodebuild build-for-testing -quiet -project "$project" -scheme OrbitTermmacOSUITests \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived_data" CODE_SIGNING_ALLOWED=NO

section "Signed macOS UI smoke contract"
# The runner itself is deliberately manual and signed. Validate its syntax in
# the ordinary gate so a release-candidate workflow cannot silently drift.
bash -n "$ORBIT_ROOT/scripts/security/run_macos_signed_ui_smoke.sh"

section "macOS Debug and Release"
xcodebuild build -quiet -project "$project" -scheme OrbitTerm_macOS -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived_data" CODE_SIGNING_ALLOWED=NO
xcodebuild build -quiet -project "$project" -scheme OrbitTerm_macOS -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived_data" CODE_SIGNING_ALLOWED=NO

section "iOS Simulator Debug and Release"
xcodebuild build -quiet -project "$project" -scheme OrbitTerm_iOS -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived_data" CODE_SIGNING_ALLOWED=NO

section "iPhoneOS arm64 Debug and Release source builds"
xcodebuild build -quiet -project "$project" -scheme OrbitTerm_iOS -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath "$derived_data" CODE_SIGNING_ALLOWED=NO
xcodebuild build -quiet -project "$project" -scheme OrbitTerm_iOS -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$derived_data" CODE_SIGNING_ALLOWED=NO
xcodebuild build -quiet -project "$project" -scheme OrbitTerm_iOS -configuration Release \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived_data" CODE_SIGNING_ALLOWED=NO

section "Release fixture exclusion"
release_binary="$derived_data/Build/Products/Release/OrbitTerm.app/Contents/MacOS/OrbitTerm"
[[ -x "$release_binary" ]] || fail "macOS Release executable not found for fixture exclusion audit"
if strings "$release_binary" | rg -i \
  '当前为模拟模式|模拟目录|进入模拟浏览|Mock 文件列表|ui-test@example[.]invalid|orbitTermUITestState|ORBITTERM_UI_TEST_STATE|fault-probe|FaultInjectionProbeBody|ScriptedURLProtocol|隐藏菜单：仅用于调试|后端地址设置'; then
  fail "Release executable contains a mock-directory or UI-test fixture marker"
fi
pass "Release executable excludes mock directories and UI-test fixtures"

section "Release build settings"
release_settings="$(xcodebuild -showBuildSettings -project "$project" -scheme OrbitTerm_macOS -configuration Release -derivedDataPath "$derived_data" 2>/dev/null)"
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
  orbit_ssh_connect_checked_v2 \
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
# XcodeGen intentionally writes a self-contained project into the temporary
# directory. Keep all source and audited toolchain references resolvable from
# that generated SRCROOT without copying or mutating repository content.
for generated_source in OrbitTerm OrbitTermCheckedFFITests orbit-core scripts .tooling; do
  ln -s "$ORBIT_ROOT/$generated_source" "$tmp_dir/$generated_source"
done
rg -q 'ORBITTERM_PUBLIC_RELEASE' "$generated_project/project.pbxproj" || fail "generated project is missing the public Release condition"
rg -q 'OrbitTermCheckedFFITests' "$generated_project/project.pbxproj" || fail "generated project is missing the checked FFI test target"
rg -q 'OrbitTermiOSUITests' "$generated_project/project.pbxproj" || fail "generated project is missing the iOS UI test target"
rg -q 'OrbitTermmacOSUITests' "$generated_project/project.pbxproj" || fail "generated project is missing the macOS UI test target"
rg -q 'ORBITTERM_PUBLIC_RELEASE' "$project/project.pbxproj" || fail "checked-in project is missing the public Release condition"
rg -q 'OrbitTermCheckedFFITests' "$project/project.pbxproj" || fail "checked-in project is missing the checked FFI test target"
rg -q 'OrbitTermiOSUITests' "$project/project.pbxproj" || fail "checked-in project is missing the iOS UI test target"
rg -q 'OrbitTermmacOSUITests' "$project/project.pbxproj" || fail "checked-in project is missing the macOS UI test target"
[[ -f "$generated_project/xcshareddata/xcschemes/OrbitTermCheckedFFITests.xcscheme" ]] || \
  fail "generated project does not expose the checked FFI test scheme"
[[ -f "$generated_project/xcshareddata/xcschemes/OrbitTermiOSUITests.xcscheme" ]] || \
  fail "generated project does not expose the iOS UI test scheme"
[[ -f "$generated_project/xcshareddata/xcschemes/OrbitTermmacOSUITests.xcscheme" ]] || \
  fail "generated project does not expose the macOS UI test scheme"
stage_checked_test_runtime "$derived_data/generated/Build/Products/Debug"
xcodebuild test -quiet -project "$generated_project" -scheme OrbitTermCheckedFFITests \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived_data/generated" CODE_SIGNING_ALLOWED=NO
pass "project.yml and checked-in project contain the same release-security targets and flags"

section "Whitespace validation"
git -C "$ORBIT_ROOT" diff --check

pass "Apple release gates"
