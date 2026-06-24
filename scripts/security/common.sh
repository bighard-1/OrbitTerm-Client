#!/usr/bin/env bash

set -euo pipefail

SECURITY_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORBIT_ROOT="$(cd "$SECURITY_SCRIPT_DIR/../.." && pwd)"

section() {
  printf '\n==> %s\n' "$1"
}

pass() {
  printf '[PASS] %s\n' "$1"
}

warn() {
  printf '[WARN] %s\n' "$1" >&2
}

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

is_macos() {
  [[ "$(uname -s)" == "Darwin" ]]
}
