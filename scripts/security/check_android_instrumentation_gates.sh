#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ANDROID_PROJECT="$ORBIT_ROOT/clients/android/OrbitTermAndroid"
ANDROID_GRADLE="$ANDROID_PROJECT/gradlew"

[[ -x "$ANDROID_GRADLE" ]] || fail "Android Gradle wrapper is missing"

section "Android connected instrumentation tests"
(
  cd "$ANDROID_PROJECT"
  ./gradlew --no-daemon \
    :core:connectedDebugAndroidTest \
    :feature:connectedDebugAndroidTest \
    :app:connectedDebugAndroidTest \
    :app:assembleSmoke
)

"$ORBIT_ROOT/scripts/security/run_android_smoke_fixtures.sh"

section "Android instrumentation test coverage"
results_root="$ANDROID_PROJECT/app/build/outputs/androidTest-results/connected"
[[ -d "$results_root" ]] || fail "connected Android test results are missing"
rg -q 'OrbitTermDatabaseMigrationTest' "$results_root" || fail "Room migration test did not run"
rg -q 'OrbitEmptyStateComposeTest' "$results_root" || fail "Compose state regression test did not run"
rg -q 'MobileRootStateComposeTest' "$results_root" || fail "mobile root-state accessibility regression test did not run"
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
