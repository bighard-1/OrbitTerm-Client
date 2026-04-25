#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

PROJECT="OrbitTerm.xcodeproj"
SCHEME_IOS="OrbitTerm_iOS"
SCHEME_MAC="OrbitTerm_macOS"
MARKETING_VERSION="1.0.0"
BUILD_VERSION="20260425"

RELEASE_ROOT="$ROOT_DIR/build/release"
MAC_OUT="$RELEASE_ROOT/macOS"
IOS_OUT="$RELEASE_ROOT/iOS"
TMP_DIR="$ROOT_DIR/build/.tmp_release"
IOS_ARCHIVE="$TMP_DIR/OrbitTerm-iOS.xcarchive"
MAC_ARCHIVE="$TMP_DIR/OrbitTerm-macOS.xcarchive"
DMG_STAGE="$TMP_DIR/dmg_stage"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "[错误] 缺少命令: $1"; exit 1; }
}

need_cmd xcodebuild
need_cmd xcodegen
need_cmd cargo
need_cmd rustup
need_cmd hdiutil
need_cmd osascript
need_cmd sips
need_cmd swift

rm -rf "$TMP_DIR"
mkdir -p "$MAC_OUT" "$IOS_OUT" "$TMP_DIR"

echo "[1/9] 生成全套 AppIcon..."
./scripts/generate_app_icons.swift

echo "[2/9] 生成 Xcode 工程并锁定版本..."
xcodegen generate >/dev/null

echo "[3/9] 构建 Rust 核心库..."
cd orbit-core
rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim >/dev/null
cargo build --target aarch64-apple-darwin >/dev/null
cargo build --target aarch64-apple-ios >/dev/null
cargo build --target aarch64-apple-ios-sim >/dev/null
cd "$ROOT_DIR"

echo "[4/9] 归档 macOS..."
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

echo "[5/9] 生成 DMG 背景图..."
BG_SRC="$ROOT_DIR/Build/Snapshots/shot2_workstation_full.png"
BG_PNG="$TMP_DIR/dmg_background.png"
if [[ -f "$BG_SRC" ]]; then
  cp "$BG_SRC" "$BG_PNG"
  sips -z 720 1080 "$BG_PNG" >/dev/null
else
  # 回退：用 Swift 快速绘制渐变背景
  cat > "$TMP_DIR/make_bg.swift" <<'SWIFT'
import AppKit
let size = NSSize(width: 1080, height: 720)
let image = NSImage(size: size)
image.lockFocus()
let colors = [NSColor(calibratedRed: 0.05, green: 0.10, blue: 0.24, alpha: 1), NSColor.black]
let gradient = NSGradient(colors: colors)!
gradient.draw(in: NSRect(origin: .zero, size: size), angle: -35)
let title = "OrbitTerm Trinity"
let attrs: [NSAttributedString.Key: Any] = [
  .font: NSFont.systemFont(ofSize: 60, weight: .bold),
  .foregroundColor: NSColor.white.withAlphaComponent(0.9)
]
let str = NSAttributedString(string: title, attributes: attrs)
str.draw(at: NSPoint(x: 70, y: 76))
image.unlockFocus()
let tiff = image.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT
  swift "$TMP_DIR/make_bg.swift" "$BG_PNG"
fi

echo "[6/9] 封装正式 DMG..."
mkdir -p "$DMG_STAGE/.background"
cp "$BG_PNG" "$DMG_STAGE/.background/background.png"
cp -R "$MAC_APP_DST" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"

RW_DMG="$TMP_DIR/OrbitTerm-rw.dmg"
FINAL_DMG="$MAC_OUT/OrbitTerm-v${MARKETING_VERSION}-build${BUILD_VERSION}.dmg"
rm -f "$RW_DMG" "$FINAL_DMG"

hdiutil create -size 700m -fs HFS+ -volname "OrbitTerm" -srcfolder "$DMG_STAGE" "$RW_DMG" >/dev/null

if DEVICE="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" 2>/dev/null | awk '/Volumes/ {print $1; exit}')"; then
  # Finder 背景和窗口布局，失败时不中断打包。
  osascript >/dev/null 2>&1 <<OSA || true
tell application "Finder"
  tell disk "OrbitTerm"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {120, 120, 980, 680}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 120
    set background picture of viewOptions to file ".background:background.png"
    set position of item "OrbitTerm.app" of container window to {250, 300}
    set position of item "Applications" of container window to {620, 300}
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
OSA

  hdiutil detach "$DEVICE" -force >/dev/null
  hdiutil convert "$RW_DMG" -format UDZO -o "$FINAL_DMG" >/dev/null
else
  echo "[提示] 当前环境不允许挂载 DMG，已降级为直接封装（仍包含背景资源文件）"
  hdiutil create -volname "OrbitTerm" -srcfolder "$DMG_STAGE" -ov -format UDZO "$FINAL_DMG" >/dev/null
fi

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
IPA_PATH="$IOS_OUT/OrbitTerm-v${MARKETING_VERSION}-build${BUILD_VERSION}.ipa"
rm -f "$IPA_PATH"
rm -rf "$TMP_DIR/Payload"
mkdir -p "$TMP_DIR/Payload"
cp -R "$IOS_APP" "$TMP_DIR/Payload/"
(
  cd "$TMP_DIR"
  zip -qry "$IPA_PATH" Payload
)

echo "[8/9] 生成 Release Note..."
cat > "$ROOT_DIR/release_note.txt" <<EOF
OrbitTerm v${MARKETING_VERSION} Trinity Workspace Edition
Build: ${BUILD_VERSION}

核心功能清单:
1. 多标签会话管理
2. 三位一体看板（服务器列表 + 终端 + 监控/SFTP）
3. 无代理性能监控（CPU/内存/磁盘/网络）
4. Docker 容器深度管理（自动发现/状态/操作/日志）
5. AES-256 零知识云同步（本地加密后上传）
EOF
cp "$ROOT_DIR/release_note.txt" "$RELEASE_ROOT/release_note.txt"

echo "[9/9] 打包完成"
ls -lah "$MAC_OUT" "$IOS_OUT" "$RELEASE_ROOT/release_note.txt"
echo "DMG: $FINAL_DMG"
echo "IPA: $IPA_PATH"
