#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

PROJECT="OrbitTerm.xcodeproj"
SCHEME_IOS="OrbitTerm_iOS"
SCHEME_MAC="OrbitTerm_macOS"
BUILD_ROOT="$ROOT_DIR/Build"
REL_IOS="$BUILD_ROOT/Release/iOS"
REL_MAC="$BUILD_ROOT/Release/macOS"
TMP_DIR="$BUILD_ROOT/tmp"
IOS_ARCHIVE="$TMP_DIR/OrbitTerm-iOS.xcarchive"
MAC_ARCHIVE="$TMP_DIR/OrbitTerm-macOS.xcarchive"

MARKETING_VERSION="1.0.0"
BUILD_NUMBER="1"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "[错误] 缺少命令: $1"; exit 1; }
}

need_cmd xcodebuild
need_cmd cargo
need_cmd swift
need_cmd xcodegen
need_cmd hdiutil
need_cmd ditto

mkdir -p "$REL_IOS" "$REL_MAC" "$TMP_DIR"

echo "[1/8] 生成 AppIcon..."
./scripts/generate_app_icons.swift

echo "[2/8] 设置版本号 ${MARKETING_VERSION} (${BUILD_NUMBER})..."
# 这里直接写入 Xcode 构建参数，避免依赖 YAML 解析工具修改 project.yml。

# 重新生成 xcodeproj，让版本/资源配置生效
xcodegen generate

echo "[3/8] 构建 Rust 核心库..."
cd orbit-core
rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim >/dev/null
cargo build --target aarch64-apple-darwin
cargo build --target aarch64-apple-ios
cargo build --target aarch64-apple-ios-sim
cd "$ROOT_DIR"

echo "[4/8] 归档 macOS (Release)..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME_MAC" \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -archivePath "$MAC_ARCHIVE" \
  ONLY_ACTIVE_ARCH=YES \
  ARCHS=arm64 \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=NO \
  archive >/dev/null

echo "[5/8] 导出 macOS 安装产物..."
MAC_APP="$MAC_ARCHIVE/Products/Applications/OrbitTerm.app"
if [[ ! -d "$MAC_APP" ]]; then
  echo "[错误] 未找到 macOS App: $MAC_APP"
  exit 1
fi

rm -f "$REL_MAC/OrbitTerm-macOS-unsigned.dmg" "$REL_MAC/OrbitTerm-macOS-unsigned.zip"
ditto -c -k --sequesterRsrc --keepParent "$MAC_APP" "$REL_MAC/OrbitTerm-macOS-unsigned.zip"
hdiutil create -volname "OrbitTerm" -srcfolder "$MAC_APP" -ov -format UDZO "$REL_MAC/OrbitTerm-macOS-unsigned.dmg" >/dev/null

echo "[6/8] 归档 iOS (Release, unsigned)..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME_IOS" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$IOS_ARCHIVE" \
  ONLY_ACTIVE_ARCH=YES \
  ARCHS=arm64 \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=NO \
  archive >/dev/null

echo "[7/8] 生成无签名 IPA..."
IOS_APP="$IOS_ARCHIVE/Products/Applications/OrbitTerm.app"
if [[ ! -d "$IOS_APP" ]]; then
  echo "[错误] 未找到 iOS App: $IOS_APP"
  exit 1
fi

IPA_PATH="$REL_IOS/OrbitTerm-iOS-unsigned.ipa"
rm -f "$IPA_PATH"
rm -rf "$TMP_DIR/Payload"
mkdir -p "$TMP_DIR/Payload"
cp -R "$IOS_APP" "$TMP_DIR/Payload/"
(
  cd "$TMP_DIR"
  zip -qry "${IPA_PATH}" Payload
)
rm -rf "$TMP_DIR/Payload"

echo "[8/8] 输出产物"
ls -lah "$REL_MAC" "$REL_IOS"

echo "[完成] 打包完成"
echo "- macOS DMG: $REL_MAC/OrbitTerm-macOS-unsigned.dmg"
echo "- iOS IPA : $REL_IOS/OrbitTerm-iOS-unsigned.ipa"
