#!/usr/bin/env bash

# Verifies only whether a real-device acceptance run can start. It never logs
# account names, device names, UDIDs, hosts, paths, commands, or credentials.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scope=""
platform=""
account_confirmed=false
assets_confirmed=false

usage() {
  cat <<'EOF'
usage: preflight_real_device_acceptance.sh --scope <tombstones|concurrency> --platform <macos|ios|android|windows|linux|windows-10|windows-11> [--test-account-confirmed] [--test-assets-confirmed]

The confirmation flags are an operator attestation only. Do not pass an
account name, device identifier, host, credential, or other secret.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) scope="${2:-}"; shift 2 ;;
    --platform) platform="${2:-}"; shift 2 ;;
    --test-account-confirmed) account_confirmed=true; shift ;;
    --test-assets-confirmed) assets_confirmed=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

case "$scope" in
  tombstones|concurrency) ;;
  *) usage >&2; exit 2 ;;
esac

case "$scope:$platform" in
  tombstones:macos|tombstones:ios|tombstones:android|tombstones:windows|tombstones:linux|concurrency:macos|concurrency:windows-10|concurrency:windows-11) ;;
  *) usage >&2; exit 2 ;;
esac

ready=true
report() {
  local label="$1"
  local status="$2"
  local detail="$3"
  printf '%-18s %-9s %s\n' "$label" "$status" "$detail"
  [[ "$status" == "READY" ]] || ready=false
}

printf 'Real-device acceptance preflight (%s / %s)\n' "$scope" "$platform"

if [[ -z "$(git -C "$root_dir" status --porcelain)" ]]; then
  report "candidate worktree" "READY" "clean candidate revision"
else
  report "candidate worktree" "MISSING" "commit or stash the current changes before collecting evidence"
fi

if "$account_confirmed"; then
  report "test account" "READY" "operator confirmed a dedicated non-production test account"
else
  report "test account" "MISSING" "operator must confirm a dedicated non-production test account"
fi

if "$assets_confirmed"; then
  report "test assets" "READY" "operator confirmed disposable, non-production test assets"
else
  report "test assets" "MISSING" "operator must confirm disposable, non-production test assets"
fi

case "$platform" in
  macos)
    if [[ "$(uname -s)" == "Darwin" ]]; then
      report "macOS device" "READY" "physical macOS host available"
    else
      report "macOS device" "MISSING" "run on a physical macOS host"
    fi
    ;;
  ios)
    if [[ "$(uname -s)" == "Darwin" ]] && command -v xcrun >/dev/null 2>&1; then
      # Count only availability; never print a device identifier.
      ios_count="$({ xcrun devicectl list devices 2>/dev/null || true; } | awk '
        /available \(paired\)/ { count += 1 }
        END { print count + 0 }
      ')"
      if (( ios_count >= 1 )); then
        report "iOS device" "READY" "at least one paired physical iOS/iPadOS device detected by Xcode"
      else
        report "iOS device" "MISSING" "connect, unlock, and trust one physical iOS/iPadOS device"
      fi
    else
      report "iOS device" "MISSING" "run from macOS with Xcode command-line tools"
    fi
    ;;
  android)
    if command -v adb >/dev/null 2>&1; then
      android_count="$(adb devices 2>/dev/null | awk 'NR > 1 && $2 == "device" && $1 !~ /^emulator-/ { count += 1 } END { print count + 0 }')"
      if (( android_count >= 1 )); then
        report "Android device" "READY" "at least one authorized physical Android device detected"
      else
        report "Android device" "MISSING" "connect and authorize one physical Android device"
      fi
    else
      report "Android device" "MISSING" "install Android platform-tools and authorize a physical device"
    fi
    ;;
  windows|windows-10|windows-11)
    case "$(uname -s)" in
      MINGW*|MSYS*|CYGWIN*|Windows_NT)
        report "Windows device" "READY" "Windows host available; confirm the required OS version separately"
        ;;
      *)
        report "Windows device" "MISSING" "run on the Windows test host"
        ;;
    esac
    ;;
  linux)
    if [[ "$(uname -s)" == "Linux" ]]; then
      report "Linux device" "READY" "Linux host available; confirm the desktop session separately"
    else
      report "Linux device" "MISSING" "run on the Linux desktop test host"
    fi
    ;;
esac

if "$ready"; then
  printf 'Preflight passed. Start only the documented %s scenario and store sanitized evidence outside source control.\n' "$scope"
  exit 0
fi

printf 'Preflight incomplete. Do not record a pass or change a release blocker.\n' >&2
exit 3
