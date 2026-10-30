#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ANDROID_PROJECT="$ORBIT_ROOT/clients/android/OrbitTermAndroid"
ANDROID_GRADLE="$ANDROID_PROJECT/gradlew"
instrumentation_profile="${ORBITTERM_ANDROID_TEST_PROFILE:-standard}"

[[ -x "$ANDROID_GRADLE" ]] || fail "Android Gradle wrapper is missing"

ADB_BIN="${ANDROID_HOME:-}/platform-tools/adb"
[[ -x "$ADB_BIN" ]] || ADB_BIN="$(command -v adb || true)"
[[ -n "$ADB_BIN" && -x "$ADB_BIN" ]] || fail "adb is unavailable"

phase_report="$ANDROID_PROJECT/build/qa-instrumentation/phases.jsonl"
run_phase() {
  python3 "$SECURITY_SCRIPT_DIR/run_bounded_phase.py" \
    --phase "$1" --timeout "$2" --report "$phase_report" -- "${@:3}"
}

wait_for_android_runtime() {
  local attempt
  "$ADB_BIN" wait-for-device
  for attempt in $(seq 1 90); do
    if [[ "$("$ADB_BIN" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]] && \
       "$ADB_BIN" shell cmd package list packages >/dev/null 2>&1 && \
       "$ADB_BIN" shell settings get global device_provisioned >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  fail "Android emulator package service did not become ready"
}

# Run readiness in its own bounded process: even adb wait-for-device or a
# nominally read-only package/settings query can hang before the retry loop.
if [[ "${1:-}" == --wait-for-runtime && $# == 1 ]]; then
  wait_for_android_runtime
  exit 0
fi
[[ $# == 0 ]] || fail 'unsupported instrumentation gate arguments'
require_command python3

capture_failure() {
  local status=$?
  # Capture only the synthetic hosted emulator, never a developer's phone.
  if (( status != 0 )) && [[ "$instrumentation_profile" == aosp-atd-api35 &&
                            "${ANDROID_SERIAL:-}" =~ ^emulator-[0-9]+$ ]]; then
    mkdir -p "$(dirname "$phase_report")"
    {
      run_phase diagnostic-device-state 10 "$ADB_BIN" get-state || true
      run_phase diagnostic-boot-state 10 "$ADB_BIN" shell getprop sys.boot_completed || true
      run_phase diagnostic-package-service 10 "$ADB_BIN" shell service check package || true
    } > "$(dirname "$phase_report")/runtime-failure.txt" 2>&1
  fi
  exit "$status"
}
trap capture_failure EXIT

results_contain() {
  local root="$1"
  local expected="$2"
  grep -R -F -q -- "$expected" "$root"
}

if [[ "$instrumentation_profile" == "aosp-atd-api35" ]]; then
  # Run the isolated fixture on the freshly booted hosted emulator. Connected
  # suites can leave a system-app ANR overlay, while rebooting afterward has
  # repeatedly left ADB install/shell stalled on hosted runners.
  # The workflow prebuilds this APK before starting the emulator.
  # Re-running Gradle after boot adds load while Android services are settling.
  [[ -f "$ANDROID_PROJECT/app/build/outputs/apk/smoke/app-x86_64-smoke.apk" ]] \
    || fail "prebuilt Android x86_64 smoke fixture APK is missing"
  run_phase runtime-before-smoke 180 bash "$SECURITY_SCRIPT_DIR/check_android_instrumentation_gates.sh" --wait-for-runtime
  run_phase smoke-fixtures 600 bash "$ORBIT_ROOT/scripts/security/run_android_smoke_fixtures.sh"
fi
section "Android connected instrumentation tests"
(
  cd "$ANDROID_PROJECT"
  case "$instrumentation_profile" in
    standard)
      ;;
    aosp-atd-api35)
      # KVM accelerates the CPU; the shared runner still uses the audited
      # SwiftShader graphics profile. Preserve memory/liveness/ANR/visual
      # gates; strict operation/frame SLA remains a normal-device requirement.
      ;;
    *)
      fail "unsupported Android instrumentation profile: ${ORBITTERM_ANDROID_TEST_PROFILE}"
      ;;
  esac
  for module in core feature app; do
    run_phase "runtime-before-$module" 180 bash "$SECURITY_SCRIPT_DIR/check_android_instrumentation_gates.sh" --wait-for-runtime
    if [[ "$instrumentation_profile" == "aosp-atd-api35" ]]; then
      run_phase "connected-$module" 900 ./gradlew --no-daemon ":${module}:connectedDebugAndroidTest" \
        -Pandroid.testInstrumentationRunnerArguments.strictPerformance=false \
        -Pandroid.testInstrumentationRunnerArguments.visualBaselineProfile=aosp-atd-api35
    else
      run_phase "connected-$module" 900 ./gradlew --no-daemon ":${module}:connectedDebugAndroidTest"
    fi
  done
)

if [[ "$instrumentation_profile" != "aosp-atd-api35" ]]; then
  (
    cd "$ANDROID_PROJECT"
    ./gradlew --no-daemon :app:assembleSmoke
  )
  "$ORBIT_ROOT/scripts/security/run_android_smoke_fixtures.sh"
fi

section "Android instrumentation test coverage"
results_root="$ANDROID_PROJECT/app/build/outputs/androidTest-results/connected"
[[ -d "$results_root" ]] || fail "connected Android test results are missing"
results_contain "$results_root" 'OrbitTermDatabaseMigrationTest' || fail "Room migration test did not run"
results_contain "$results_root" 'AssetSyncOutboxBatchTest' || fail "bounded sync outbox FIFO test did not run"
results_contain "$results_root" 'processEquivalentDatabaseReopenPreservesUnfinishedBacklogAndAccountIsolation' || fail "sync interruption database-reopen test did not run"
results_contain "$results_root" 'retryAfterSurvivesStorageAndPreventsEarlySelection' || fail "Retry-After restart, unlock and account-isolation test did not run"
results_contain "$results_root" 'OrbitEmptyStateComposeTest' || fail "Compose state regression test did not run"
results_contain "$results_root" 'MobileRootStateComposeTest' || fail "mobile root-state accessibility regression test did not run"
results_contain "$results_root" 'SyncRecoveryComposeTest' || fail "sync/recovery state regression test did not run"
results_contain "$results_root" 'SecurityOperationComposeTest' || fail "security operation accessibility regression test did not run"
feature_results_root="$ANDROID_PROJECT/feature/build/outputs/androidTest-results/connected"
[[ -d "$feature_results_root" ]] || fail "feature connected Android test results are missing"
results_contain "$feature_results_root" 'SftpStateAccessibilityComposeTest' || fail "SFTP state accessibility regression test did not run"
results_contain "$feature_results_root" 'SftpCancelledDocumentProviderTest' || fail "SFTP cancelled-target provider regression test did not run"
results_contain "$feature_results_root" 'TerminalReconnectAccessibilityComposeTest' || fail "terminal reconnect accessibility regression test did not run"
results_contain "$results_root" 'statusBadgeExposesTextualStateBeyondItsColor' || fail "status badge accessibility regression test did not run"
results_contain "$results_root" 'OrbitDesignScreenshotBaselineTest' || fail "design screenshot baseline test did not run"
results_contain "$results_root" 'P2AccessibilityLayoutRegressionTest' || fail "P2 accessibility layout regression test did not run"
results_contain "$results_root" 'PerformanceBaselineInstrumentationTest' || fail "performance baseline test did not run"
core_results_root="$ANDROID_PROJECT/core/build/outputs/androidTest-results/connected"
[[ -d "$core_results_root" ]] || fail "core connected Android test results are missing"
results_contain "$core_results_root" 'TerminalPerformanceInstrumentationTest' || fail "terminal performance test did not run"

pass "Android instrumentation gates"
