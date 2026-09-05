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

section "Android connected instrumentation tests"
(
  cd "$ANDROID_PROJECT"
  for module in core feature app; do
    wait_for_android_runtime
    ./gradlew --no-daemon ":${module}:connectedDebugAndroidTest"
  done
  ./gradlew --no-daemon :app:assembleSmoke
)

"$ORBIT_ROOT/scripts/security/run_android_smoke_fixtures.sh"

section "Android instrumentation test coverage"
results_root="$ANDROID_PROJECT/app/build/outputs/androidTest-results/connected"
[[ -d "$results_root" ]] || fail "connected Android test results are missing"
rg -q 'OrbitTermDatabaseMigrationTest' "$results_root" || fail "Room migration test did not run"
rg -q 'AssetSyncOutboxBatchTest' "$results_root" || fail "bounded sync outbox FIFO test did not run"
rg -q 'processEquivalentDatabaseReopenPreservesUnfinishedBacklogAndAccountIsolation' "$results_root" || fail "sync interruption database-reopen test did not run"
rg -q 'retryAfterSurvivesStorageAndPreventsEarlySelection' "$results_root" || fail "Retry-After restart, unlock and account-isolation test did not run"
rg -q 'OrbitEmptyStateComposeTest' "$results_root" || fail "Compose state regression test did not run"
rg -q 'MobileRootStateComposeTest' "$results_root" || fail "mobile root-state accessibility regression test did not run"
rg -q 'SyncRecoveryComposeTest' "$results_root" || fail "sync/recovery state regression test did not run"
rg -q 'SecurityOperationComposeTest' "$results_root" || fail "security operation accessibility regression test did not run"
feature_results_root="$ANDROID_PROJECT/feature/build/outputs/androidTest-results/connected"
[[ -d "$feature_results_root" ]] || fail "feature connected Android test results are missing"
rg -q 'SftpStateAccessibilityComposeTest' "$feature_results_root" || fail "SFTP state accessibility regression test did not run"
rg -q 'TerminalReconnectAccessibilityComposeTest' "$feature_results_root" || fail "terminal reconnect accessibility regression test did not run"
rg -q 'statusBadgeExposesTextualStateBeyondItsColor' "$results_root" || fail "status badge accessibility regression test did not run"
rg -q 'OrbitDesignScreenshotBaselineTest' "$results_root" || fail "design screenshot baseline test did not run"
rg -q 'P2AccessibilityLayoutRegressionTest' "$results_root" || fail "P2 accessibility layout regression test did not run"
rg -q 'PerformanceBaselineInstrumentationTest' "$results_root" || fail "performance baseline test did not run"
core_results_root="$ANDROID_PROJECT/core/build/outputs/androidTest-results/connected"
[[ -d "$core_results_root" ]] || fail "core connected Android test results are missing"
rg -q 'TerminalPerformanceInstrumentationTest' "$core_results_root" || fail "terminal performance test did not run"

pass "Android instrumentation gates"
