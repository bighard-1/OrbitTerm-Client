#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_DIR="$ROOT_DIR/orbit-core"
ANDROID_CLIENT_ROOT="$ROOT_DIR/clients/android/OrbitTermAndroid/app/src/main/jniLibs"
DEFAULT_NDK_HOME="$ROOT_DIR/.tooling/android-sdk/ndk/29.0.14206865"
if [[ ! -d "$DEFAULT_NDK_HOME" ]]; then
  DEFAULT_NDK_HOME="${HOME}/Library/Android/sdk/ndk/29.0.14206865"
fi
ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-$DEFAULT_NDK_HOME}}"

if [[ ! -d "$ANDROID_NDK_HOME" ]]; then
  echo "Android NDK not found: $ANDROID_NDK_HOME" >&2
  exit 1
fi

export ANDROID_NDK_HOME
# Android NDK host tags differ between local macOS development and Linux CI.
# Resolve only supported host toolchains so the Rust build remains source-based
# in both environments instead of depending on prebuilt `.so` files.
for host_tag in darwin-aarch64 darwin-x86_64 linux-x86_64 linux-aarch64; do
  candidate="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$host_tag/bin"
  if [[ -d "$candidate" ]]; then
    TOOLCHAIN_DIR="$candidate"
    break
  fi
done
if [[ -z "${TOOLCHAIN_DIR:-}" ]]; then
  echo "Android NDK host toolchain is unavailable in $ANDROID_NDK_HOME" >&2
  exit 1
fi
cd "$CORE_DIR"

# Keep emulator and physical-device builds in sync. Override ANDROID_RUST_TARGETS
# only for deliberately narrower local builds.
android_rust_targets="${ANDROID_RUST_TARGETS:-aarch64-linux-android x86_64-linux-android}"
for target in $android_rust_targets; do
  case "$target" in
    aarch64-linux-android) android_abi="arm64-v8a" ;;
    x86_64-linux-android) android_abi="x86_64" ;;
    *) echo "Unsupported Android Rust target: $target" >&2; exit 1 ;;
  esac

  target_key="${target//-/_}"
  target_key_upper="$(printf '%s' "$target_key" | tr '[:lower:]' '[:upper:]')"
  linker="$TOOLCHAIN_DIR/${target}35-clang"
  if [[ ! -x "$linker" ]]; then linker="$TOOLCHAIN_DIR/${target}34-clang"; fi
  if [[ ! -x "$linker" ]]; then
    echo "Android clang linker not found for $target in $TOOLCHAIN_DIR" >&2
    exit 1
  fi

  # Native dependencies such as ring invoke the C compiler through cc-rs rather
  # than Cargo's linker setting. Keep both paths aligned with the same NDK API.
  export "AR_${target_key}=$TOOLCHAIN_DIR/llvm-ar"
  export "CC_${target_key}=$linker"
  export "CXX_${target_key}=${linker%clang}clang++"
  export "CARGO_TARGET_${target_key_upper}_LINKER=$linker"

  cargo build --release --target "$target"
  destination="$ANDROID_CLIENT_ROOT/$android_abi"
  mkdir -p "$destination"
  cp "$CORE_DIR/target/$target/release/liborbit_core.so" "$destination/liborbit_core.so"
  echo "Copied liborbit_core.so to $destination"
done
