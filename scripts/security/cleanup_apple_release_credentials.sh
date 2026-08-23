#!/usr/bin/env bash

set -euo pipefail

if [[ -n "${ORBITTERM_RELEASE_KEYCHAIN_PATH:-}" && -f "$ORBITTERM_RELEASE_KEYCHAIN_PATH" ]]; then
  security delete-keychain "$ORBITTERM_RELEASE_KEYCHAIN_PATH" || true
fi

if [[ -n "${RUNNER_TEMP:-}" ]]; then
  find "$RUNNER_TEMP" -maxdepth 2 \( -name '*.p12' -o -name 'AuthKey.p8' -o -name 'ExportOptions.plist' \) -delete 2>/dev/null || true
fi
