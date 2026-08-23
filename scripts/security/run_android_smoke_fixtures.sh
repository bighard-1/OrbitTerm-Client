#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

adb_bin="${ANDROID_ADB:-$(command -v adb || true)}"
if [[ -z "$adb_bin" ]]; then
  sdk_root="${ANDROID_HOME:-$ORBIT_ROOT/.tooling/android-sdk}"
  adb_bin="$sdk_root/platform-tools/adb"
fi
[[ -x "$adb_bin" ]] || fail "adb is unavailable; configure ANDROID_HOME or ANDROID_ADB"

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

cleanup() {
  "$adb_bin" -s "$SERIAL" shell rm -f "$remote_xml" >/dev/null 2>&1 || true
  "$adb_bin" -s "$SERIAL" uninstall "$package" >/dev/null 2>&1 || true
}
trap cleanup EXIT

"$adb_bin" -s "$SERIAL" install -r "$apk" >/dev/null

assert_state() {
  local state="$1"
  local expected="$2"
  # A fixture is a fresh, deterministic process per state. This only stops the
  # isolated .smoke package; the production package is never addressed here.
  "$adb_bin" -s "$SERIAL" shell am force-stop "$package"
  "$adb_bin" -s "$SERIAL" shell am start -W -n "$activity" \
    --es com.orbitterm.android.smoke.fixture.STATE "$state" >/dev/null
  # `am start -W` waits for Activity launch, not Compose's first committed frame.
  sleep 1
  "$adb_bin" -s "$SERIAL" shell uiautomator dump "$remote_xml" >/dev/null
  "$adb_bin" -s "$SERIAL" shell cat "$remote_xml" | grep -Fq "$expected" \
    || fail "smoke fixture '$state' did not expose '$expected'"
}

section "Android isolated smoke fixtures"
assert_state locked "解锁工作台"
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
