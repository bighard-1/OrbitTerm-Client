#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_ROOT="${ROOT_DIR}/.tooling/freerdp-macos/install"
OUTPUT="${ROOT_DIR}/.tooling/freerdp-macos/remote_desktop_runtime_test"

clang -std=c11 -Wall -Wextra -Werror -Wno-deprecated-declarations \
  -I "${ROOT_DIR}/OrbitTerm/CBridge" \
  -I "${RUNTIME_ROOT}/freerdp/include/freerdp3" \
  -I "${RUNTIME_ROOT}/freerdp/include/winpr3" \
  "${ROOT_DIR}/OrbitTerm/CBridge/orbit_remote_desktop.c" \
  "${ROOT_DIR}/tests/native/remote_desktop_runtime_test.c" \
  -L "${RUNTIME_ROOT}/freerdp/lib" \
  -lfreerdp3 -lfreerdp-client3 -lwinpr3 \
  -Wl,-rpath,"${RUNTIME_ROOT}/freerdp/lib" \
  -Wl,-rpath,"${RUNTIME_ROOT}/openssl/lib" \
  -o "${OUTPUT}"

"${OUTPUT}"
