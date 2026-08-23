#!/usr/bin/env bash

set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
destination="${1:-$HOME/Desktop/OrbitTerm.app}"
derived_data="${ORBITTERM_LOCAL_DERIVED_DATA:-$root_dir/build/local-macos-signed}"
team_id="${ORBITTERM_APPLE_TEAM_ID:-BYZK354JK4}"
project="$root_dir/OrbitTerm.xcodeproj"
scheme="OrbitTerm_macOS"
staging="${destination}.installing.$$"
backup="${destination}.previous.$$"
entitlements_file=""

cleanup() {
  [[ -z "$entitlements_file" ]] || rm -f "$entitlements_file"
  rm -rf "$staging"
  if [[ -d "$backup" && ! -d "$destination" ]]; then
    mv "$backup" "$destination"
  fi
}
trap cleanup EXIT

for command_name in xcodebuild codesign ditto plutil; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "[错误] 缺少命令：$command_name" >&2
    exit 1
  }
done

echo "[1/5] 构建带 Apple Development 签名的 macOS Release 应用……"
xcodebuild build \
  -project "$project" \
  -scheme "$scheme" \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="$team_id"

source_app="$derived_data/Build/Products/Release/OrbitTerm.app"
[[ -d "$source_app" ]] || {
  echo "[错误] 未找到构建产物：$source_app" >&2
  exit 1
}

echo "[2/5] 校验签名身份和 Keychain 权限……"
codesign --verify --deep --strict --verbose=2 "$source_app"
signature_info="$(codesign -dvv "$source_app" 2>&1)"
grep -q '^Authority=Apple Development:' <<<"$signature_info" || {
  echo "[错误] 本机构建不是 Apple Development 签名，拒绝安装会导致 Keychain -34018 的产物。" >&2
  exit 1
}
grep -q "^TeamIdentifier=$team_id$" <<<"$signature_info" || {
  echo "[错误] 签名团队不匹配，预期：$team_id" >&2
  exit 1
}

entitlements_file="$(mktemp "${TMPDIR:-/tmp}/orbitterm-entitlements.XXXXXX")"
codesign -d --entitlements :- "$source_app" >"$entitlements_file" 2>/dev/null
access_group="$(plutil -extract keychain-access-groups.0 raw -o - "$entitlements_file" 2>/dev/null || true)"
expected_access_group="$team_id.com.orbitterm.app"
[[ "$access_group" == "$expected_access_group" ]] || {
  echo "[错误] Keychain 访问组缺失或错误。实际：${access_group:-<空>}；预期：$expected_access_group" >&2
  exit 1
}

echo "[3/5] 暂停旧客户端并准备原样复制签名产物……"
osascript -e 'tell application id "com.orbitterm.app" to quit' >/dev/null 2>&1 || true
for _ in {1..20}; do
  pgrep -x OrbitTerm >/dev/null 2>&1 || break
  sleep 0.1
done

rm -rf "$staging"
ditto "$source_app" "$staging"
codesign --verify --deep --strict --verbose=2 "$staging"

echo "[4/5] 原子替换本地客户端……"
if [[ -e "$destination" ]]; then
  mv "$destination" "$backup"
fi
mv "$staging" "$destination"
codesign --verify --deep --strict --verbose=2 "$destination"
rm -rf "$backup"

echo "[5/5] 启动最新版……"
open "$destination"

echo "[完成] 已安装：$destination"
echo "[完成] TeamIdentifier：$team_id"
echo "[完成] Keychain access group：$access_group"
