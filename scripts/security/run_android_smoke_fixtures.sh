#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

adb_bin="${ANDROID_ADB:-$(command -v adb || true)}"
if [[ -z "$adb_bin" ]]; then
  sdk_root="${ANDROID_HOME:-$ORBIT_ROOT/.tooling/android-sdk}"
  adb_bin="$sdk_root/platform-tools/adb"
fi
[[ -x "$adb_bin" ]] || fail "adb is unavailable; configure ANDROID_HOME or ANDROID_ADB"
require_command python3

ANDROID_PROJECT="$ORBIT_ROOT/clients/android/OrbitTermAndroid"
SERIAL="${ANDROID_SERIAL:-}"
if [[ -z "$SERIAL" ]]; then
  SERIAL="$($adb_bin devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')"
fi
[[ -n "$SERIAL" ]] || fail "no running Android emulator/device found"

abi="$($adb_bin -s "$SERIAL" shell getprop ro.product.cpu.abi | tr -d '\r')"
case "$abi" in
  arm64-v8a) apk="$ANDROID_PROJECT/app/build/outputs/apk/smoke/app-arm64-v8a-smoke.apk" ;;
  x86_64) apk="$ANDROID_PROJECT/app/build/outputs/apk/smoke/app-x86_64-smoke.apk" ;;
  *) fail "unsupported smoke fixture ABI: $abi" ;;
esac
[[ -f "$apk" ]] || fail "smoke APK is missing; run :app:assembleSmoke first"

package="com.orbitterm.android.smoke"
activity="$package/com.orbitterm.android.smoke.SmokeFixtureActivity"
remote_xml="/sdcard/orbitterm-smoke-fixture.xml"
snapshot_attempts="${ORBITTERM_ANDROID_SMOKE_SNAPSHOT_ATTEMPTS:-30}"

[[ "$snapshot_attempts" =~ ^[1-9][0-9]*$ ]] \
  || fail "ORBITTERM_ANDROID_SMOKE_SNAPSHOT_ATTEMPTS must be a positive integer"

cleanup() {
  bounded_adb 20 shell rm -f "$remote_xml" >/dev/null 2>&1 || true
  bounded_adb 30 uninstall "$package" >/dev/null 2>&1 || true
}
trap cleanup EXIT

bounded_adb() {
  local seconds="$1"
  shift
  python3 - "$seconds" "$adb_bin" -s "$SERIAL" "$@" <<'PY'
import subprocess
import sys

seconds = int(sys.argv[1])
try:
    result = subprocess.run(sys.argv[2:], timeout=seconds, check=False)
except subprocess.TimeoutExpired:
    print(f"ADB command timed out after {seconds}s: {sys.argv[5]}", file=sys.stderr)
    raise SystemExit(124)
raise SystemExit(result.returncode)
PY
}

install_smoke_fixture() {
  local attempt output max_attempts=3
  if [[ "${ORBITTERM_ANDROID_TEST_PROFILE:-}" == "aosp-atd-api35" ]]; then
    max_attempts=5
  fi
  section "Install Android isolated smoke fixture"
  for attempt in $(seq 1 "$max_attempts"); do
    if output="$(bounded_adb 90 install -r "$apk" 2>&1)"; then
      return 0
    fi
    case "$output" in
      *"Can't find service: package"*|*"Cannot access system provider: 'settings' before system providers are installed!"*)
        # ADB and PackageManager can answer before Android has installed its
        # system providers. An APK install still fails at that stage.
        if (( attempt < max_attempts )); then
          warn "Android install services are not ready; waiting for recovery ($attempt/$max_attempts)"
          local ready=false probe
          for probe in $(seq 1 45); do
            if bounded_adb 20 shell cmd package list packages >/dev/null 2>&1 && \
               bounded_adb 20 shell settings get global device_provisioned >/dev/null 2>&1; then
              ready=true
              break
            fi
            sleep 2
          done
          [[ "$ready" == true ]] || fail "Android emulator install services did not recover after fixture install failure"
          continue
        fi
        ;;
      *"Broken pipe"*|*"device offline"*|*"Connection reset"*|*"ADB command timed out"*)
        if (( attempt < max_attempts )); then
          warn "transient ADB transport failure during isolated fixture install; retrying ($attempt/$max_attempts)"
          sleep 3
          continue
        fi
        ;;
      *"PackageManagerInternal.freeStorage"*"on a null object reference"*|\
      *"StorageManager.getVolumes()' on a null object reference"*"InstallLocationUtils.resolveInstallVolume"*)
        # The hosted software-only ATD can report boot_completed and answer
        # package queries before its package/storage install dependencies are
        # initialized. Both signatures originate in Android system-server,
        # before an APK assertion. Retry only these startup signatures; keep
        # the final raw failure if the services do not recover.
        if [[ "${ORBITTERM_ANDROID_TEST_PROFILE:-}" == "aosp-atd-api35" ]] &&
           (( attempt < max_attempts )); then
          warn "Android ATD storage/package services are still initializing; retrying fixture install ($attempt/$max_attempts)"
          sleep 10
          continue
        fi
        ;;
    esac
    printf '%s\n' "$output" >&2
    fail "isolated smoke fixture APK installation failed"
  done
}

install_smoke_fixture
atd_anr_dismissals=0

dismiss_atd_fake_system_anr() {
  local snapshot="$1" tap x y
  [[ "${ORBITTERM_ANDROID_TEST_PROFILE:-}" == "aosp-atd-api35" ]] || return 1
  tap="$(printf '%s' "$snapshot" | python3 -c '
import re
import sys
import xml.etree.ElementTree as ET

try:
    nodes = list(ET.fromstring(sys.stdin.read()).iter("node"))
except ET.ParseError:
    raise SystemExit(1)

if not any(node.get("resource-id") == "android:id/alertTitle"
           and node.get("text") == "Fake System App isn\x27t responding"
           for node in nodes):
    raise SystemExit(1)

for node in nodes:
    if node.get("resource-id") != "android:id/aerr_close" or node.get("text") != "Close app":
        continue
    match = re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.get("bounds", ""))
    if match:
        left, top, right, bottom = map(int, match.groups())
        print((left + right) // 2, (top + bottom) // 2)
        raise SystemExit(0)
raise SystemExit(1)
')" || return 1
  read -r x y <<< "$tap"
  warn "dismissing isolated AOSP ATD Fake System App ANR overlay"
  bounded_adb 20 shell input tap "$x" "$y"
}

assert_state() {
  local state="$1"
  local expected="$2"
  local attempt
  local fixture_xml
  section "Android isolated smoke fixture: $state"
  # A fixture is a fresh, deterministic process per state. This only stops the
  # isolated .smoke package; the production package is never addressed here.
  bounded_adb 30 shell am force-stop "$package"
  bounded_adb 45 shell am start -W -n "$activity" \
    --es com.orbitterm.android.smoke.fixture.STATE "$state" >/dev/null
  # `am start -W` waits for Activity launch, not Compose's first committed
  # frame. Software-rendered emulators can expose it late, so poll the
  # accessibility tree rather than trusting a fixed one-second snapshot.
  for attempt in $(seq 1 "$snapshot_attempts"); do
    bounded_adb 20 shell rm -f "$remote_xml" >/dev/null 2>&1 || true
    if bounded_adb 30 shell uiautomator dump "$remote_xml" >/dev/null 2>&1; then
      fixture_xml="$(bounded_adb 20 shell cat "$remote_xml" 2>/dev/null || true)"
      if [[ "${ORBITTERM_ANDROID_TEST_PROFILE:-}" == "aosp-atd-api35" &&
            "$fixture_xml" == *"Fake System App isn"* ]]; then
        if (( atd_anr_dismissals < 2 )) && dismiss_atd_fake_system_anr "$fixture_xml"; then
          (( atd_anr_dismissals += 1 ))
          continue
        fi
        fail "isolated AOSP ATD Fake System App ANR overlay persisted or could not be safely identified"
      fi
      if [[ "$fixture_xml" == *"$expected"* ]]; then
        return
      fi
    fi
    sleep 1
  done
  warn "foreground activity at smoke-fixture failure:"
  bounded_adb 20 shell dumpsys activity activities 2>/dev/null \
    | grep -E 'mResumedActivity|topResumedActivity' \
    | head -4 \
    || true
  warn "last accessibility snapshot (isolated fixture data only):"
  printf '%s\n' "${fixture_xml:-<unavailable>}"
  fail "smoke fixture '$state' did not expose '$expected' after $snapshot_attempts accessibility snapshots"
}

section "Android isolated smoke fixtures"
assert_state locked "验证主密码"
assert_state light "浅色主题夹具"
assert_state dark "深色主题夹具"
assert_state empty-session "暂无活动会话。请先在服务器页连接一台资产。"
assert_state connection-failure "诊断代码：ssh_timeout。"
assert_state sync-failure "同步失败，请检查网络和登录状态后重试。"
assert_state docker-empty "当前已连接服务器没有可管理的 Docker 容器。"
assert_state transfer-queue "传输队列 · 2 个待处理项目"
assert_state host-key-challenge "诊断代码：host_key_challenge。"
assert_state authentication-failure "诊断代码：ssh_auth_failed。"
assert_state offline "当前离线，网络恢复后将自动同步。"
assert_state sync-conflict "同一资产在本机与云端均有修改。"
assert_state transfer-feedback "诊断代码：destination_unwritable。"
assert_state reconnect-recovery "网络已恢复，正在重新连接。"
assert_state large-transfer-paused "网络已中断，传输已安全暂停。"
assert_state terminal-stress "终端输出压力夹具 · 4,096 个数据块"

pass "Android isolated smoke fixtures"
