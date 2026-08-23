#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

matrix="$ORBIT_ROOT/docs/PLATFORM_BEHAVIOR_ALIGNMENT_MATRIX.md"
[[ -f "$matrix" ]] || fail "cross-platform behavior alignment matrix is missing"
acceptance="$ORBIT_ROOT/docs/PLATFORM_REAL_DEVICE_ACCEPTANCE.md"
[[ -f "$acceptance" ]] || fail "cross-platform real-device acceptance record is missing"

section "iOS/macOS/Android behavior alignment matrix"
rg -q '^# OrbitTerm iOS / macOS / Android 行为对齐矩阵$' "$matrix" || \
  fail "cross-platform behavior alignment matrix has an unexpected title"

for scope in 'Host Key' '跳板机' 'Telnet' 'SFTP' 'Docker' 'Monitor' '同步' '无障碍' '发布证据'; do
  rg -Fq "$scope" "$matrix" || fail "cross-platform behavior alignment matrix is missing required scope: $scope"
done

awk -F'|' '
  /^\| / {
    # The primary iOS/macOS/Android matrix has eight semantic columns (plus
    # the two pipe delimiters seen by awk). Supplemental platform tables use
    # their own smaller schema and are reviewed by their dedicated gates.
    if (NF < 10) {
      next
    }
    domain = $2
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", domain)
    if (domain == "域" || domain ~ /^---/) {
      next
    }
    for (column = 2; column <= 9; column++) {
      if ($column !~ /[^[:space:]]/) {
        printf("incomplete alignment row at line %d\n", NR) > "/dev/stderr"
        exit 1
      }
    }
    status = $7
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", status)
    if (status != "已对齐" && status != "有意差异" && status != "待完成") {
      printf("invalid alignment status at line %d: %s\n", NR, status) > "/dev/stderr"
      exit 1
    }
  }
' "$matrix" || fail "cross-platform behavior alignment matrix contains incomplete or invalid rows"

pass "iOS/macOS/Android behavior alignment matrix"

section "cross-platform real-device acceptance preparation"
for scope in 'iPhone / iPad' 'macOS' 'Android' 'VoiceOver' 'TalkBack' 'Telnet'; do
  rg -Fq "$scope" "$acceptance" || fail "real-device acceptance record is missing required scope: $scope"
done
pass "cross-platform real-device acceptance preparation"
