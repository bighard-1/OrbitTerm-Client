#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command unzip
require_command shasum

ANDROID_PROJECT="$ORBIT_ROOT/clients/android/OrbitTermAndroid"
ANDROID_GRADLE="$ANDROID_PROJECT/gradlew"
ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ORBIT_ROOT}/.tooling/android-sdk/ndk/29.0.14206865}"

[[ -x "$ANDROID_GRADLE" ]] || fail "Android Gradle wrapper is missing"
[[ -d "$ANDROID_NDK_HOME" ]] || fail "ANDROID_NDK_HOME is missing"
[[ -f "$ANDROID_PROJECT/app/gradle.lockfile" ]] || fail "Android dependency lockfile is missing"
protected_release_workflow="$ORBIT_ROOT/.github/workflows/android-protected-release.yml"
[[ -f "$protected_release_workflow" ]] || fail "Android protected release workflow is missing"

section "Android checked native build"
ANDROID_NDK_HOME="$ANDROID_NDK_HOME" "$ORBIT_ROOT/scripts/build_android_core.sh"

section "Android unit tests and Release assembly"
"$ORBIT_ROOT/scripts/security/check_android_architecture.sh"
"$ORBIT_ROOT/scripts/security/check_android_ios_alignment_matrix.sh"
"$ORBIT_ROOT/scripts/security/check_platform_behavior_alignment_matrix.sh"
(
  cd "$ANDROID_PROJECT"
  ANDROID_NDK_HOME="$ANDROID_NDK_HOME" ./gradlew --no-daemon \
    :app:testDebugUnitTest \
    :feature:testDebugUnitTest \
    :app:verifyReleaseSigning \
    :app:assembleRelease \
    :app:assembleSmoke
)

unit_results_root="$ANDROID_PROJECT/app/build/test-results/testDebugUnitTest"
[[ -d "$unit_results_root" ]] || fail "Android unit-test results are missing"
rg -q 'AndroidTransportSupportPolicyTest' "$unit_results_root" || \
  fail "Android Telnet transport-policy regression test did not run"
feature_unit_results_root="$ANDROID_PROJECT/feature/build/test-results/testDebugUnitTest"
[[ -d "$feature_unit_results_root" ]] || fail "Android feature unit-test results are missing"
rg -q 'SftpShareArchivePolicyTest' "$feature_unit_results_root" || \
  fail "Android SFTP share-policy regression test did not run"
rg -q 'SftpPathNavigationTest' "$feature_unit_results_root" || \
  fail "Android SFTP path-policy regression test did not run"
rg -q 'TerminalSpecialKeyOrderTest' "$feature_unit_results_root" || \
  fail "Android terminal special-key regression test did not run"

section "Android release artifacts"
release_dir="$ANDROID_PROJECT/app/build/outputs/apk/release"
release_apks=()
while IFS= read -r apk; do
  release_apks+=("$apk")
done < <(find "$release_dir" -maxdepth 1 -type f -name '*.apk' | sort)
[[ "${#release_apks[@]}" -gt 0 ]] || fail "no Release APK was produced"

smoke_dir="$ANDROID_PROJECT/app/build/outputs/apk/smoke"
smoke_apks=()
while IFS= read -r apk; do
  smoke_apks+=("$apk")
done < <(find "$smoke_dir" -maxdepth 1 -type f -name '*.apk' | sort)
[[ "${#smoke_apks[@]}" -gt 0 ]] || fail "no isolated smoke APK was produced"

sdk_root="${ANDROID_HOME:-$ORBIT_ROOT/.tooling/android-sdk}"
aapt_bin="$(find "$sdk_root/build-tools" -path '*/aapt' -type f | sort | tail -1)"
apksigner_bin="$(find "$sdk_root/build-tools" -path '*/apksigner' -type f | sort | tail -1)"
[[ -x "$aapt_bin" ]] || fail "aapt is unavailable"
[[ -x "$apksigner_bin" ]] || fail "apksigner is unavailable"
for apk in "${smoke_apks[@]}"; do
  smoke_package="$($aapt_bin dump badging "$apk" | sed -n "s/^package: name='\([^']*\)'.*/\1/p")"
  [[ "$smoke_package" == "com.orbitterm.android.smoke" ]] || fail "smoke APK is not isolated: $apk"
  "$aapt_bin" dump xmltree "$apk" AndroidManifest.xml | grep -q 'SmokeFixtureActivity' \
    || fail "smoke fixture Activity is missing: $apk"
  smoke_signing="$($apksigner_bin verify --verbose --print-certs "$apk")"
  grep -q 'CN=Android Debug' <<< "$smoke_signing" || fail "smoke APK is not debug-signed: $apk"
done

toolchain_dir="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-aarch64/bin"
[[ -x "$toolchain_dir/llvm-readelf" ]] || toolchain_dir="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin"
readelf_bin="$toolchain_dir/llvm-readelf"
[[ -x "$readelf_bin" ]] || fail "llvm-readelf is unavailable"

for apk in "${release_apks[@]}"; do
  unzip -tq "$apk" >/dev/null
  if "$aapt_bin" dump xmltree "$apk" AndroidManifest.xml | grep -q 'SmokeFixtureActivity'; then
    fail "smoke fixture leaked into Release APK: $apk"
  fi
  case "$(basename "$apk")" in
    *arm64-v8a*) expected_abi="arm64-v8a" ;;
    *x86_64*) expected_abi="x86_64" ;;
    *) fail "unexpected unsplit Release APK: $apk" ;;
  esac
  libraries=()
  while IFS= read -r library; do
    libraries+=("$library")
  done < <(unzip -Z1 "$apk" 'lib/*/*.so')
  [[ "${#libraries[@]}" -gt 0 ]] || fail "Release APK has no native libraries: $apk"
  for library in "${libraries[@]}"; do
    [[ "$library" == "lib/$expected_abi/"* ]] || fail "unexpected ABI in $apk: $library"
    temporary_library="$(mktemp)"
    unzip -p "$apk" "$library" > "$temporary_library"
    if "$readelf_bin" -S "$temporary_library" | grep -Eq '\.debug_|\.zdebug_'; then
      rm -f "$temporary_library"
      fail "debug sections are packaged in $apk: $library"
    fi
    rm -f "$temporary_library"
  done
  shasum -a 256 "$apk"
done

section "Source safety checks"
if rg -n 'android\.util\.Log\.|printStackTrace\(' "$ANDROID_PROJECT/app/src/main"; then
  fail "debug logging is present in Android production source"
fi
rg -q 'isMinifyEnabled = true' "$ANDROID_PROJECT/app/build.gradle.kts" || fail "Release minification is disabled"
rg -q 'isShrinkResources = true' "$ANDROID_PROJECT/app/build.gradle.kts" || fail "Release resource shrinking is disabled"
rg -q 'buildOrbitAndroidCore' "$ANDROID_PROJECT/app/build.gradle.kts" || fail "Release does not build Rust from source"
rg -q 'lockAllConfigurations' "$ANDROID_PROJECT/app/build.gradle.kts" || fail "Android dependency locking is disabled"
rg -q 'applicationIdSuffix = "\.smoke"' "$ANDROID_PROJECT/app/build.gradle.kts" || fail "isolated smoke application ID is missing"
rg -q 'verifyReleaseSigning' "$ANDROID_PROJECT/app/build.gradle.kts" || fail "production signing verification is missing"
rg -q 'android-production-signing' "$protected_release_workflow" || fail "protected signing environment is missing"
rg -q 'ORBITTERM_RELEASE_KEYSTORE_BASE64' "$protected_release_workflow" || fail "protected keystore input is missing"
rg -q 'collect_android_release_evidence\.sh' "$protected_release_workflow" || fail "release evidence collection is missing"
rg -q 'Remove protected signing key' "$protected_release_workflow" || fail "protected key cleanup is missing"
rg -q 'Verify successful CI gates for release commit' "$protected_release_workflow" || fail "successful CI verification is missing"
rg -q 'git verify-tag' "$protected_release_workflow" || fail "signed tag verification is missing"

pass "Android Release gates"
