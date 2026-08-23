#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command shasum
require_command unzip

ANDROID_PROJECT="$ORBIT_ROOT/clients/android/OrbitTermAndroid"
APK_DIRECTORY="${1:-$ANDROID_PROJECT/app/build/outputs/apk/release}"
EVIDENCE_DIRECTORY="${2:-}"

[[ -n "$EVIDENCE_DIRECTORY" ]] || fail "usage: $0 <signed-apk-directory> <evidence-directory>"
[[ -d "$APK_DIRECTORY" ]] || fail "APK directory is missing: $APK_DIRECTORY"
[[ ! -e "$EVIDENCE_DIRECTORY" ]] || fail "evidence directory must not already exist: $EVIDENCE_DIRECTORY"
[[ -z "$(git -C "$ORBIT_ROOT" status --porcelain)" ]] || fail "release evidence requires a clean worktree"

sdk_root="${ANDROID_HOME:-$ORBIT_ROOT/.tooling/android-sdk}"
# Build-tools directories use dotted numeric versions; lexical ordering is
# sufficient for the supported major versions and works with macOS BSD sort.
apksigner="$(find "$sdk_root/build-tools" -path '*/apksigner' -type f | sort | tail -1)"
[[ -x "$apksigner" ]] || fail "apksigner is unavailable; install Android Build Tools"

artifacts=()
while IFS= read -r artifact; do
  artifacts+=("$artifact")
done < <(find "$APK_DIRECTORY" -maxdepth 1 -type f \( -name '*.apk' -o -name '*.aab' \) | sort)
[[ "${#artifacts[@]}" -gt 0 ]] || fail "no APK/AAB artifacts found in $APK_DIRECTORY"

mkdir -p "$EVIDENCE_DIRECTORY"
metadata="$EVIDENCE_DIRECTORY/android-release-metadata.txt"
{
  printf 'commit_sha=%s\n' "$(git -C "$ORBIT_ROOT" rev-parse HEAD)"
  printf 'tree_sha=%s\n' "$(git -C "$ORBIT_ROOT" rev-parse HEAD^{tree})"
  printf 'utc_timestamp=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'apk_directory=%s\n' "$APK_DIRECTORY"
  printf 'android_gradle_plugin=8.12.1\n'
} > "$metadata"

checksums="$EVIDENCE_DIRECTORY/artifact-checksums.txt"
signing="$EVIDENCE_DIRECTORY/signing-verification.txt"
for artifact in "${artifacts[@]}"; do
  case "$artifact" in
    *.apk)
      unzip -tq "$artifact" >/dev/null
      "$apksigner" verify --verbose --print-certs "$artifact" >> "$signing"
      if rg -qi 'Android Debug|CN=Android Debug' "$signing"; then
        fail "debug-signed artifact is not releasable: $(basename "$artifact")"
      fi
      ;;
    *.aab)
      unzip -tq "$artifact" >/dev/null
      printf 'AAB signature must be verified by the protected Play/App Signing flow: %s\n' "$(basename "$artifact")" >> "$signing"
      ;;
  esac
  shasum -a 256 "$artifact" >> "$checksums"
done

pass "Android release evidence collected in $EVIDENCE_DIRECTORY"
