#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

PROJECT="OrbitTerm.xcodeproj"
SCHEME_IOS="OrbitTerm_iOS"
SCHEME_MAC="OrbitTerm_macOS"
MARKETING_VERSION="1.0.1"
BUILD_VERSION="20260624"

RELEASE_ROOT="$ROOT_DIR/build/release"
MAC_OUT="$RELEASE_ROOT/macOS"
IOS_OUT="$RELEASE_ROOT/iOS"
TMP_DIR="$ROOT_DIR/build/.tmp_release"
IOS_ARCHIVE="$TMP_DIR/OrbitTerm-iOS.xcarchive"
MAC_ARCHIVE="$TMP_DIR/OrbitTerm-macOS.xcarchive"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "[错误] 缺少命令: $1"; exit 1; }
}

need_cmd xcodebuild
need_cmd cargo
need_cmd rustup
need_cmd hdiutil
need_cmd swift
need_cmd git

if [[ -n "$(git status --porcelain)" ]]; then
  echo "[错误] Release packaging 必须从 clean worktree 运行。" >&2
  exit 1
fi
SOURCE_COMMIT="$(git rev-parse HEAD)"

rm -rf "$TMP_DIR"
mkdir -p "$MAC_OUT" "$IOS_OUT" "$TMP_DIR"

echo "[1/9] 生成全套 AppIcon..."
./scripts/generate_app_icons.swift

echo "[2/9] 验证不可变 Xcode 工程..."
echo "[提示] 使用 commit 中的 project.yml 和 OrbitTerm.xcodeproj，打包期间不重新生成工程。"

echo "[3/9] 构建 Rust 核心库..."
./scripts/build_apple_core.sh

echo "[4/9] 收集可追溯构建证据..."
"$ROOT_DIR/scripts/security/collect_apple_build_evidence.sh" "$RELEASE_ROOT/evidence" >/dev/null

echo "[5/9] 归档 macOS..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME_MAC" \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -archivePath "$MAC_ARCHIVE" \
  ONLY_ACTIVE_ARCH=YES \
  ARCHS=arm64 \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_VERSION" \
  CODE_SIGNING_ALLOWED=NO \
  archive >/dev/null

MAC_APP_SRC="$MAC_ARCHIVE/Products/Applications/OrbitTerm.app"
MAC_APP_DST="$MAC_OUT/OrbitTerm.app"
rm -rf "$MAC_APP_DST"
cp -R "$MAC_APP_SRC" "$MAC_APP_DST"

echo "[6/9] 封装标准拖拽式 DMG..."
FINAL_DMG="$MAC_OUT/OrbitTerm-v${MARKETING_VERSION}-build${BUILD_VERSION}-unsigned.dmg"
rm -f "$FINAL_DMG"
"$ROOT_DIR/scripts/create_macos_drag_dmg.sh" "$MAC_APP_DST" "$FINAL_DMG" "OrbitTerm" >/dev/null

echo "[7/9] 归档 iOS 并导出 IPA..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME_IOS" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$IOS_ARCHIVE" \
  ONLY_ACTIVE_ARCH=YES \
  ARCHS=arm64 \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_VERSION" \
  CODE_SIGNING_ALLOWED=NO \
  archive >/dev/null

IOS_APP="$IOS_ARCHIVE/Products/Applications/OrbitTerm.app"
IPA_PATH="$IOS_OUT/OrbitTerm-v${MARKETING_VERSION}-build${BUILD_VERSION}-unsigned.ipa"
rm -f "$IPA_PATH"
rm -rf "$TMP_DIR/Payload"
mkdir -p "$TMP_DIR/Payload"
cp -R "$IOS_APP" "$TMP_DIR/Payload/"
(
  cd "$TMP_DIR"
  zip -qry "$IPA_PATH" Payload
)

echo "[8/9] 生成 Release Note..."
test -f "$ROOT_DIR/release_note.txt" || {
  echo "[错误] 缺少 release_note.txt" >&2
  exit 1
}
cp "$ROOT_DIR/release_note.txt" "$RELEASE_ROOT/release_note.txt"

echo "[9/9] 无签名打包完成"
ls -lah "$MAC_OUT" "$IOS_OUT" "$RELEASE_ROOT/release_note.txt"
echo "DMG: $FINAL_DMG"
echo "IPA: $IPA_PATH"
echo "[提示] 以上产物尚未签名或 notarize，不得直接对外发布。"

if [[ "$(git rev-parse HEAD)" != "$SOURCE_COMMIT" ]] || [[ -n "$(git status --porcelain)" ]]; then
  echo "[错误] Packaging 改变了 RC source tree，产物不可用。" >&2
  exit 1
fi
