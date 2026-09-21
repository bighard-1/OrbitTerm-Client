#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ANDROID_PROJECT="$ORBIT_ROOT/clients/android/OrbitTermAndroid"
ANDROID_GRADLE="$ANDROID_PROJECT/gradlew"

[[ -x "$ANDROID_GRADLE" ]] || fail "Android Gradle wrapper is missing"

ADB_BIN="${ANDROID_HOME:-}/platform-tools/adb"
[[ -x "$ADB_BIN" ]] || ADB_BIN="$(command -v adb || true)"
[[ -n "$ADB_BIN" && -x "$ADB_BIN" ]] || fail "adb is unavailable"

wait_for_android_runtime() {
  local attempt
  "$ADB_BIN" wait-for-device
  for attempt in $(seq 1 60); do
    if [[ "$("$ADB_BIN" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]] && \
       "$ADB_BIN" shell cmd package list packages >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  fail "Android emulator package service did not become ready"
}

results_contain() {
  local root="$1"
  local expected="$2"
  grep -R -F -q -- "$expected" "$root"
}

section "Android connected instrumentation tests"
(
  cd "$ANDROID_PROJECT"
  instrumentation_profile="${ORBITTERM_ANDROID_TEST_PROFILE:-standard}"
  case "$instrumentation_profile" in
    standard)
      ;;
    aosp-atd-api35)
      # The hosted Ubuntu runner has no hardware acceleration. Preserve memory,
      # liveness, ANR, semantics, and renderer-specific visual gates while the
      # 8-second operation/frame SLA remains enforced on normal local devices.
      ;;
    *)
      fail "unsupported Android instrumentation profile: ${ORBITTERM_ANDROID_TEST_PROFILE}"
      ;;
  esac
  for module in core feature app; do
    wait_for_android_runtime
    if [[ "$instrumentation_profile" == "aosp-atd-api35" ]]; then
      ./gradlew --no-daemon ":${module}:connectedDebugAndroidTest" \
        -Pandroid.testInstrumentationRunnerArguments.strictPerformance=false \
        -Pandroid.testInstrumentationRunnerArguments.visualBaselineProfile=aosp-atd-api35
    else
      ./gradlew --no-daemon ":${module}:connectedDebugAndroidTest"
    fi
  done
  ./gradlew --no-daemon :app:assembleSmoke
)

"$ORBIT_ROOT/scripts/security/run_android_smoke_fixtures.sh"

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
results_contain "$feature_results_root" 'TerminalReconnectAccessibilityComposeTest' || fail "terminal reconnect accessibility regression test did not run"
results_contain "$results_root" 'statusBadgeExposesTextualStateBeyondItsColor' || fail "status badge accessibility regression test did not run"
results_contain "$results_root" 'OrbitDesignScreenshotBaselineTest' || fail "design screenshot baseline test did not run"
results_contain "$results_root" 'P2AccessibilityLayoutRegressionTest' || fail "P2 accessibility layout regression test did not run"
results_contain "$results_root" 'PerformanceBaselineInstrumentationTest' || fail "performance baseline test did not run"
core_results_root="$ANDROID_PROJECT/core/build/outputs/androidTest-results/connected"
[[ -d "$core_results_root" ]] || fail "core connected Android test results are missing"
results_contain "$core_results_root" 'TerminalPerformanceInstrumentationTest' || fail "terminal performance test did not run"

pass "Android instrumentation gates"
