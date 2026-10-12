#!/usr/bin/env bash

# The iPhone acceptance app must remain distinguishable from the formal app.
# Use this entry point for every Release-configuration iOS QA candidate.
set -euo pipefail

if [[ $# -ne 1 || ! "$1" =~ ^[0-9]{8}\.[0-9]+$ ]]; then
  echo "Usage: $0 YYYYMMDD.build" >&2
  exit 2
fi

build_number="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data="${ORBITTERM_IOS_QA_DERIVED_DATA:-/private/tmp/orbitterm-ios-release-qa-${build_number}}"
team_id="${ORBITTERM_APPLE_TEAM_ID:-BYZK354JK4}"
app_path="${derived_data}/Build/Products/Release-iphoneos/OrbitTerm.app"

for tool_name in cargo xcodebuild codesign shasum; do
  command -v "$tool_name" >/dev/null 2>&1 || {
    echo "Missing required tool: $tool_name" >&2
    exit 1
  }
done

(
  cd "${repo_root}/orbit-core"
  IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo build --locked --release --target aarch64-apple-ios
)

xcodebuild build -quiet \
  -project "${repo_root}/OrbitTerm.xcodeproj" \
  -scheme OrbitTerm_iOS \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived_data" \
  PRODUCT_BUNDLE_IDENTIFIER=com.orbitterm.matrix.ios \
  ORBITTERM_DISPLAY_NAME='OrbitTerm QA' \
  CURRENT_PROJECT_VERSION="$build_number" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="$team_id"

test -d "$app_path"
codesign --verify --deep --strict "$app_path"

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Info.plist")"
display_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$app_path/Info.plist")"
bundle_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$app_path/Info.plist")"
actual_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Info.plist")"
if [[ "$bundle_id" != com.orbitterm.matrix.ios || "$display_name" != 'OrbitTerm QA' || "$bundle_name" != 'OrbitTerm QA' || "$actual_build" != "$build_number" ]]; then
  echo "QA identity check failed; refusing to use this build." >&2
  exit 1
fi

echo "QA app: $app_path"
echo "QA identity: $display_name ($bundle_id), build $actual_build"
shasum -a 256 "$app_path/OrbitTerm"
