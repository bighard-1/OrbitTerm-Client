#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

matrix="$ORBIT_ROOT/docs/ANDROID_IOS_BEHAVIOR_ALIGNMENT_MATRIX.md"
[[ -f "$matrix" ]] || fail "Android/iOS behavior alignment matrix is missing"

section "Android/iOS behavior alignment matrix"
rg -q '^# Android / iOS 行为对齐矩阵$' "$matrix" || fail "alignment matrix has an unexpected title"

required_rows=(
  'Telnet'
  '多选文件与目录后一键批量下载/系统分享'
  'TalkBack'
  'Android 前台服务与常驻通知'
)
for row in "${required_rows[@]}"; do
  rg -Fq "$row" "$matrix" || fail "alignment matrix is missing required scope: $row"
done

while IFS= read -r row; do
  [[ "$row" == *' 域 | 操作结果 / 安全语义 '* ]] && continue
  [[ "$row" == *' --- '* ]] && continue
  IFS='|' read -r _ domain behavior ios android status owner acceptance _ <<< "$row"
  [[ -n "${domain// }" && -n "${behavior// }" && -n "${ios// }" && -n "${android// }" ]] || fail "alignment matrix has an incomplete row"
  case "${status// }" in
    已对齐|有意差异|待完成) ;;
    *) fail "alignment matrix row has an invalid status: $status" ;;
  esac
  [[ -n "${owner// }" && -n "${acceptance// }" ]] || fail "alignment matrix row is missing owner or acceptance criteria"
done < <(rg '^\| ' "$matrix")

pass "Android/iOS behavior alignment matrix"
