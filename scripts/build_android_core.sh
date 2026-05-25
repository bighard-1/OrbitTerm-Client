#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_DIR="$ROOT_DIR/orbit-core"
ANDROID_CLIENT="$ROOT_DIR/clients/android/OrbitTermAndroid/app/src/main/jniLibs/arm64-v8a"
ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-$HOME/Library/Android/sdk/ndk/29.0.14206865}}"

if [[ ! -d "$ANDROID_NDK_HOME" ]]; then
  echo "Android NDK not found: $ANDROID_NDK_HOME" >&2
  exit 1
fi

export ANDROID_NDK_HOME
TOOLCHAIN_DIR="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-aarch64/bin"
if [[ ! -d "$TOOLCHAIN_DIR" ]]; then
  TOOLCHAIN_DIR="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin"
fi
export AR_aarch64_linux_android="$TOOLCHAIN_DIR/llvm-ar"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$TOOLCHAIN_DIR/aarch64-linux-android35-clang"

if [[ ! -x "$CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER" ]]; then
  export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$TOOLCHAIN_DIR/aarch64-linux-android34-clang"
fi

if [[ ! -x "$CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER" ]]; then
  echo "Android clang linker not found in $TOOLCHAIN_DIR" >&2
  exit 1
fi

cd "$CORE_DIR"
cargo build --release --target aarch64-linux-android
mkdir -p "$ANDROID_CLIENT"
cp "$CORE_DIR/target/aarch64-linux-android/release/liborbit_core.so" "$ANDROID_CLIENT/liborbit_core.so"
echo "Copied liborbit_core.so to $ANDROID_CLIENT"
