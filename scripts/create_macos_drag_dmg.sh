#!/usr/bin/env zsh
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 /path/to/OrbitTerm.app /path/to/output.dmg [VolumeName]"
  exit 64
fi

APP_SRC="$1"
DMG_OUT="$2"
VOL_NAME="${3:-OrbitTerm}"

if [[ ! -d "$APP_SRC" ]]; then
  echo "[错误] 未找到 App: $APP_SRC"
  exit 1
fi

if ! command -v hdiutil >/dev/null 2>&1; then
  echo "[错误] 未检测到 hdiutil，无法生成 macOS DMG。"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orbitterm-dmg.XXXXXX")"
STAGE_DIR="$TMP_ROOT/stage"
RW_DMG="$TMP_ROOT/${VOL_NAME}-rw.dmg"

cleanup() {
  hdiutil detach "/Volumes/$VOL_NAME" -force >/dev/null 2>&1 || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$STAGE_DIR/.background"
cp -R "$APP_SRC" "$STAGE_DIR/OrbitTerm.app"
ln -s /Applications "$STAGE_DIR/Applications"

BG_PNG="$STAGE_DIR/.background/background.png"
cat > "$TMP_ROOT/make_dmg_background.swift" <<'SWIFT'
import AppKit

let outputPath = CommandLine.arguments[1]
let size = NSSize(width: 760, height: 440)
let image = NSImage(size: size)
image.lockFocus()

let rect = NSRect(origin: .zero, size: size)
NSColor(calibratedRed: 0.035, green: 0.045, blue: 0.075, alpha: 1).setFill()
rect.fill()

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.02, green: 0.45, blue: 0.95, alpha: 0.45),
    NSColor(calibratedRed: 0.30, green: 0.12, blue: 0.85, alpha: 0.18),
    NSColor(calibratedRed: 0.035, green: 0.045, blue: 0.075, alpha: 1)
])!
gradient.draw(in: rect, angle: -25)

let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 32, weight: .bold),
    .foregroundColor: NSColor.white.withAlphaComponent(0.92)
]
NSAttributedString(string: "OrbitTerm", attributes: titleAttrs).draw(at: NSPoint(x: 42, y: 360))

let subtitleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 14, weight: .medium),
    .foregroundColor: NSColor.white.withAlphaComponent(0.62)
]
NSAttributedString(string: "Drag OrbitTerm into Applications to install.", attributes: subtitleAttrs)
    .draw(at: NSPoint(x: 43, y: 335))

let arrowAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 72, weight: .thin),
    .foregroundColor: NSColor(calibratedRed: 0.0, green: 0.90, blue: 1.0, alpha: 0.55)
]
NSAttributedString(string: "→", attributes: arrowAttrs).draw(at: NSPoint(x: 350, y: 175))

image.unlockFocus()
let tiff = image.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: outputPath))
SWIFT

if command -v swift >/dev/null 2>&1; then
  swift "$TMP_ROOT/make_dmg_background.swift" "$BG_PNG" >/dev/null
else
  cp "$ROOT_DIR/OrbitTerm/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" "$BG_PNG" 2>/dev/null || true
fi

rm -f "$DMG_OUT" "$RW_DMG"
mkdir -p "$(dirname "$DMG_OUT")"

hdiutil create -size 180m -fs HFS+ -volname "$VOL_NAME" -srcfolder "$STAGE_DIR" "$RW_DMG" >/dev/null

if DEVICE="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" 2>/dev/null | awk '/Volumes/ {print $1; exit}')"; then
  osascript >/dev/null 2>&1 <<OSA || true
tell application "Finder"
  tell disk "$VOL_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {160, 120, 920, 560}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 104
    set background picture of viewOptions to file ".background:background.png"
    set position of item "OrbitTerm.app" of container window to {220, 240}
    set position of item "Applications" of container window to {540, 240}
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
OSA
  hdiutil detach "$DEVICE" -force >/dev/null
fi

hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_OUT" >/dev/null
echo "[完成] 标准拖拽式 DMG: $DMG_OUT"
