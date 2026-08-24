#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_ROOT="${ROOT_DIR}/.tooling/freerdp-macos/install"
OUTPUT="${ROOT_DIR}/.tooling/freerdp-macos/remote_desktop_runtime_test"

clang -std=c11 -Wall -Wextra -Werror \
  -I "${ROOT_DIR}/OrbitTerm/CBridge" \
  "${ROOT_DIR}/OrbitTerm/CBridge/orbit_remote_desktop.c" \
  "${ROOT_DIR}/tests/native/remote_desktop_runtime_test.c" \
  -Wl,-rpath,"${RUNTIME_ROOT}/freerdp/lib" \
  -Wl,-rpath,"${RUNTIME_ROOT}/openssl/lib" \
  -o "${OUTPUT}"

"${OUTPUT}"
