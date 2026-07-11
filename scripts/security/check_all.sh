#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

section "Static scans"
"$SECURITY_SCRIPT_DIR/check_static_scans.sh"

if [[ -x "$ORBIT_ROOT/clients/windows/scripts/check_windows_static.sh" ]]; then
  section "Windows client static scans"
  "$ORBIT_ROOT/clients/windows/scripts/check_windows_static.sh"
fi

section "Rust gates"
"$SECURITY_SCRIPT_DIR/check_rust_release_gates.sh"

section "Header and ABI symbols"
"$SECURITY_SCRIPT_DIR/check_symbols.sh"

section "Apple gates"
"$SECURITY_SCRIPT_DIR/check_apple_release_gates.sh"

section "Final whitespace validation"
git -C "$ORBIT_ROOT" diff --check

pass "All OrbitTerm security gates"
printf '[RC] Run ORBITTERM_RUN_OPENSSH_SMOKE=1 scripts/security/run_openssh_smoke.sh before release.\n'
