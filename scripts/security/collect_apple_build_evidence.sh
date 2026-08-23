#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${1:?usage: collect_apple_build_evidence.sh <output-directory>}"
mkdir -p "$OUT_DIR"

require_file() {
  [[ -f "$1" ]] || { echo "missing required file: $1" >&2; exit 1; }
}

require_file "$ROOT/orbit-core/Cargo.lock"
require_file "$ROOT/OrbitTerm.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
require_file "$ROOT/OrbitTerm/OrbitTerm.entitlements"
require_file "$ROOT/OrbitTerm/App/PrivacyInfo.xcprivacy"

commit="$(git -C "$ROOT" rev-parse HEAD)"
package_hash="$(shasum -a 256 "$ROOT/OrbitTerm.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" | awk '{print $1}')"
cargo_hash="$(shasum -a 256 "$ROOT/orbit-core/Cargo.lock" | awk '{print $1}')"

libraries=(
  "aarch64-apple-darwin/release"
  "aarch64-apple-ios/release"
  "aarch64-apple-ios-sim/release"
)

{
  printf 'source_commit=%s\n' "$commit"
  printf 'spm_lock_sha256=%s\n' "$package_hash"
  printf 'cargo_lock_sha256=%s\n' "$cargo_hash"
  printf 'entitlements_sha256=%s\n' "$(shasum -a 256 "$ROOT/OrbitTerm/OrbitTerm.entitlements" | awk '{print $1}')"
  printf 'privacy_manifest_sha256=%s\n' "$(shasum -a 256 "$ROOT/OrbitTerm/App/PrivacyInfo.xcprivacy" | awk '{print $1}')"
  for suffix in "${libraries[@]}"; do
    library="$ROOT/orbit-core/target/$suffix/liborbit_core.a"
    require_file "$library"
    printf 'rust_library_%s_sha256=%s\n' "${suffix//\//_}" "$(shasum -a 256 "$library" | awk '{print $1}')"
    # Newer Rust object metadata can be ahead of the host Xcode nm reader.
    # Archive member symbol strings remain stable provenance evidence without
    # making the release gate depend on that reader-version mismatch. The
    # separate ABI gate performs linker-level symbol verification.
    symbols_file="$OUT_DIR/symbols-${suffix//\//-}.txt"
    strings "$library" | rg '^_?orbit_[A-Za-z0-9_]+$' | sort -u > "$symbols_file"
    for symbol in orbit_ssh_connect_checked_v2 orbit_terminal_open_checked_v1 orbit_sftp_open_checked_v1 orbit_exec_checked_v1; do
      grep -qx "_$symbol\|$symbol" "$symbols_file" || {
        echo "missing checked symbol in $suffix: $symbol" >&2
        exit 1
      }
    done
  done
} > "$OUT_DIR/build-evidence.properties"

plutil -lint "$ROOT/OrbitTerm/OrbitTerm.entitlements" > "$OUT_DIR/entitlements-lint.txt"
plutil -lint "$ROOT/OrbitTerm/App/PrivacyInfo.xcprivacy" > "$OUT_DIR/privacy-manifest-lint.txt"
cp "$ROOT/OrbitTerm/OrbitTerm.entitlements" "$OUT_DIR/OrbitTerm.entitlements"
cp "$ROOT/OrbitTerm/App/PrivacyInfo.xcprivacy" "$OUT_DIR/PrivacyInfo.xcprivacy"
"$ROOT/scripts/security/collect_apple_sbom.sh" "$OUT_DIR/apple-client-sbom.cdx.json" >/dev/null

echo "Apple build evidence written to $OUT_DIR"
