#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CORE_DIR="$ROOT_DIR/orbit-core"
MACOS_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
IOS_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"

cd "$CORE_DIR"
rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim >/dev/null

for profile in debug release; do
  if [[ "$profile" == "release" ]]; then
    MACOSX_DEPLOYMENT_TARGET="$MACOS_TARGET" cargo build --release --target aarch64-apple-darwin
    IPHONEOS_DEPLOYMENT_TARGET="$IOS_TARGET" cargo build --release --target aarch64-apple-ios
    IPHONEOS_DEPLOYMENT_TARGET="$IOS_TARGET" cargo build --release --target aarch64-apple-ios-sim
  else
    MACOSX_DEPLOYMENT_TARGET="$MACOS_TARGET" cargo build --target aarch64-apple-darwin
    IPHONEOS_DEPLOYMENT_TARGET="$IOS_TARGET" cargo build --target aarch64-apple-ios
    IPHONEOS_DEPLOYMENT_TARGET="$IOS_TARGET" cargo build --target aarch64-apple-ios-sim
  fi
done
