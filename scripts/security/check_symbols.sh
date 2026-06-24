#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command nm
require_command cc

LEGACY_SYMBOLS=(
  orbit_test_ssh_connection
  orbit_ssh_connect
  orbit_sftp_connect
  orbit_request_channel
  orbit_exec_command
  orbit_fetch_system_stats
  orbit_fetch_docker_containers
  orbit_fetch_docker_stats
  orbit_fetch_docker_logs
  orbit_docker_action
  orbit_free_string
)

CHECKED_SYMBOLS=(
  orbit_test_ssh_connection_checked_v1
  orbit_ssh_connect_checked_v1
  orbit_terminal_open_checked_v1
  orbit_sftp_open_checked_v1
  orbit_monitor_snapshot_checked_v1
  orbit_docker_list_checked_v1
  orbit_docker_stats_checked_v1
  orbit_docker_logs_checked_v1
  orbit_docker_action_checked_v1
  orbit_exec_checked_v1
  orbit_hostkey_challenge_accept_and_persist_v1
)

section "Canonical and forwarding C headers"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/orbitterm-header-gate.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
cat >"$tmp_dir/header_check.c" <<'EOF'
#include "orbit-core/include/orbit_core.h"
#include "OrbitTerm/CBridge/orbit_core.h"

int main(void) {
    (void)&orbit_ssh_connect;
    (void)&orbit_ssh_connect_checked_v1;
    (void)&orbit_terminal_open_checked_v1;
    (void)&orbit_sftp_open_checked_v1;
    (void)&orbit_monitor_snapshot_checked_v1;
    (void)&orbit_docker_list_checked_v1;
    (void)&orbit_exec_checked_v1;
    return 0;
}
EOF
cc -std=c11 -Wall -Wextra -Werror -pedantic -fsyntax-only -I"$ORBIT_ROOT" "$tmp_dir/header_check.c"
grep -Fq '#include "../../orbit-core/include/orbit_core.h"' \
  "$ORBIT_ROOT/OrbitTerm/CBridge/orbit_core.h" || fail "Apple CBridge header is not forwarding to the canonical Rust header"
if grep -Eq '^[[:space:]]*(char|void|int|uint[0-9]+_t)[[:space:]]+\*?orbit_' \
  "$ORBIT_ROOT/OrbitTerm/CBridge/orbit_core.h"; then
  fail "Apple forwarding header contains an independent ABI declaration"
fi
pass "C11 headers and forwarding include"

section "Rust dynamic-library ABI symbols"
if is_macos; then
  library="$ORBIT_ROOT/orbit-core/target/release/liborbit_core.dylib"
  [[ -f "$library" ]] || fail "missing Release dylib; run check_rust_release_gates.sh first"
  symbols="$(nm -gU "$library" | awk '{print $NF}')"
else
  library="$ORBIT_ROOT/orbit-core/target/release/liborbit_core.so"
  [[ -f "$library" ]] || fail "missing Release shared library; run check_rust_release_gates.sh first"
  symbols="$(nm -D -g --defined-only "$library" | awk '{print $NF}')"
fi

for symbol in "${LEGACY_SYMBOLS[@]}"; do
  grep -qx "_\?$symbol" <<<"$symbols" || fail "legacy ABI symbol missing: $symbol"
done
for symbol in "${CHECKED_SYMBOLS[@]}"; do
  grep -qx "_\?$symbol" <<<"$symbols" || fail "checked ABI symbol missing: $symbol"
done
pass "legacy and checked ABI symbols are exported"
