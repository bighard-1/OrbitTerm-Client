#!/usr/bin/env zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "[错误] 未检测到 xcodebuild，请先安装 Xcode。"
  exit 1
fi
if ! command -v cargo >/dev/null 2>&1; then
  echo "[错误] 未检测到 cargo，请先安装 Rust。"
  exit 1
fi

mkdir -p dist
rm -rf build

# 1) 构建 Rust 静态库，供 Swift 链接。
cd orbit-core
rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim
cargo build --target aarch64-apple-darwin
cargo build --target aarch64-apple-ios
cargo build --target aarch64-apple-ios-sim
cd "$ROOT_DIR"

# 2) 构建 macOS Release（ARM64）。
xcodebuild \
  -project OrbitTerm.xcodeproj \
  -scheme OrbitTerm_macOS \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build \
  ONLY_ACTIVE_ARCH=YES \
  ARCHS=arm64 \
  CODE_SIGNING_ALLOWED=NO \
  build

# 3) 构建 iOS Simulator Release（ARM64）。
xcodebuild \
  -project OrbitTerm.xcodeproj \
  -scheme OrbitTerm_iOS \
  -configuration Release \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build \
  ONLY_ACTIVE_ARCH=YES \
  ARCHS=arm64 \
  CODE_SIGNING_ALLOWED=NO \
  build

# 4) 生成 iOS 真机归档（未签名）。
xcodebuild \
  -project OrbitTerm.xcodeproj \
  -scheme OrbitTerm_iOS \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath dist/OrbitTerm-iOS-Device.xcarchive \
  ONLY_ACTIVE_ARCH=YES \
  ARCHS=arm64 \
  CODE_SIGNING_ALLOWED=NO \
  archive

# 5) 打包产物。
rm -f dist/OrbitTerm-macOS-arm64-unsigned.zip dist/OrbitTerm-iOS-simulator-arm64-unsigned.zip

ditto -c -k --sequesterRsrc --keepParent \
  build/Build/Products/Release/OrbitTerm.app \
  dist/OrbitTerm-macOS-arm64-unsigned.zip

ditto -c -k --sequesterRsrc --keepParent \
  build/Build/Products/Release-iphonesimulator/OrbitTerm.app \
  dist/OrbitTerm-iOS-simulator-arm64-unsigned.zip

echo "[完成] 客户端打包成功，产物目录：$ROOT_DIR/dist"
ls -lah dist
