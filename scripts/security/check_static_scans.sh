#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command rg

ALLOWLIST="$SECURITY_SCRIPT_DIR/known_blockers.allowlist"
[[ -f "$ALLOWLIST" ]] || fail "missing blocker allowlist: $ALLOWLIST"
STATIC_SCAN_ALLOWLIST="$SECURITY_SCRIPT_DIR/static_scan.allowlist"
[[ -f "$STATIC_SCAN_ALLOWLIST" ]] || fail "missing static-scan allowlist: $STATIC_SCAN_ALLOWLIST"

scan_swift_requires_internal_guard() {
  local pattern="$1"
  local label="$2"
  local failed=0
  while IFS= read -r file; do
    if ! awk -v pattern="$pattern" '
      BEGIN { depth = 0; guard_depth = 0; bad = 0 }
      /^[[:space:]]*#if/ {
        depth++
        if ($0 ~ /DEBUG[[:space:]]*&&[[:space:]]*ORBITTERM_INTERNAL_LEGACY_NETWORK/ && guard_depth == 0) {
          guard_depth = depth
        }
      }
      $0 ~ pattern {
        if (guard_depth == 0) {
          printf "%s:%d:%s\n", FILENAME, NR, $0
          bad = 1
        }
      }
      /^[[:space:]]*#else/ {
        if (guard_depth == depth) guard_depth = 0
      }
      /^[[:space:]]*#elseif/ {
        if (guard_depth == depth) guard_depth = 0
      }
      /^[[:space:]]*#endif/ {
        if (guard_depth == depth) guard_depth = 0
        depth--
      }
      END { exit bad }
    ' "$file"; then
      failed=1
    fi
  done < <(find "$ORBIT_ROOT/OrbitTerm" -name '*.swift' -type f -print)
  [[ "$failed" -eq 0 ]] || fail "$label"
}

section "Swift forbidden UX and obsolete flags"
if rg -ni --glob '*.swift' \
  'trust[[:space:]_-]*all|accept[[:space:]_-]*anyway|全部信任|仍然接受' \
  "$ORBIT_ROOT/OrbitTerm"; then
  fail "forbidden Host Key trust UX text found"
fi
if rg -n 'ORBITTERM_INTERNAL_CHECKED_CONNECTION|debugInternalOnly|case[[:space:]]+disabled' \
  "$ORBIT_ROOT/OrbitTerm" "$ORBIT_ROOT/project.yml" "$ORBIT_ROOT/OrbitTerm.xcodeproj/project.pbxproj"; then
  fail "obsolete checked-migration policy or flag found"
fi
pass "Host Key UX and obsolete policy scans"

section "Swift Host Key protocol parsing"
if rg -n '"(OK:|ERR:)' \
  "$ORBIT_ROOT/OrbitTerm/Core/CheckedFFI" \
  "$ORBIT_ROOT/OrbitTerm/Core/HostKeyTrust" \
  "$ORBIT_ROOT/OrbitTerm/Features/Security"; then
  fail "checked Host Key code parses a legacy OK:/ERR: response"
fi
pass "checked Host Key code uses structured envelopes"

section "Swift checked-service legacy calls"
if rg -n 'RustFFI[.]connectSFTP[[:space:]]*\(|orbit_request_channel[[:space:]]*\(|orbit_exec_command[[:space:]]*\(|orbit_fetch_docker_(containers|stats|logs)[[:space:]]*\(|orbit_docker_action[[:space:]]*\(' \
  "$ORBIT_ROOT/OrbitTerm/Core/CheckedFFI"; then
  fail "checked Swift service calls a legacy connection/channel/exec API"
fi
scan_swift_requires_internal_guard \
  'orbit_(ssh_connect|test_ssh_connection|sftp_connect|request_channel|exec_command|fetch_system_stats|fetch_docker_containers|fetch_docker_stats|fetch_docker_logs|docker_action)[[:space:]]*[(]' \
  "dangerous legacy C call is not internal-build guarded"
scan_swift_requires_internal_guard '[.]legacyInternal' \
  "legacyInternal is constructible outside its internal-build guard"
scan_swift_requires_internal_guard 'TelnetClient[[:space:]]*[(]' \
  "Telnet connection construction is reachable outside its internal-build guard"
pass "Swift legacy calls are compile guarded"

section "Rust checked-path isolation"
checked_rust_files=()
while IFS= read -r file; do checked_rust_files+=("$file"); done < <(
  find "$ORBIT_ROOT/orbit-core/src" -type f \
    \( -name 'checked_*.rs' -o -path '*/security/checked_*.rs' \) -print
)
if rg -n 'resolve_base_session[[:space:]]*\(' "${checked_rust_files[@]}"; then
  fail "checked Rust module uses the mixed-ID resolver"
fi
if rg -n 'run_remote_command[[:space:]]*\(' "${checked_rust_files[@]}"; then
  fail "checked Rust module calls legacy remote exec"
fi
if rg -n '(debug!|info!|warn!|error!|println!|eprintln!).*(private_key|public_key|known_hosts|command|stdout|stderr|docker.*logs)' \
  "${checked_rust_files[@]}"; then
  fail "checked Rust logging may expose sensitive payloads"
fi
pass "checked Rust modules avoid mixed resolver, legacy exec, and sensitive logs"

section "Rust host-key handler policy"
checked_handler="orbit-core/src/security/checked_host_key_handler.rs"
insecure_handler="orbit-core/src/security/insecure_legacy_host_key_handler.rs"
grep -Fqx "checked_trusted_proceed|$checked_handler|HostKeyVerificationDecision::Proceed" \
  "$STATIC_SCAN_ALLOWLIST" || fail "checked trusted-proceed exception is missing or too broad"
grep -Fqx "internal_legacy_accept_all|$insecure_handler|legacy-network-internal" \
  "$STATIC_SCAN_ALLOWLIST" || fail "internal legacy handler exception is missing or too broad"

[[ "$(rg -n 'Ok\(true\)' "$ORBIT_ROOT/$checked_handler" | wc -l | tr -d ' ')" == "1" ]] || \
  fail "checked handler must contain exactly one trusted Proceed return"
rg -q 'HostKeyVerificationDecision::Proceed' "$ORBIT_ROOT/$checked_handler" || \
  fail "checked handler Ok(true) is not bound to the trusted Proceed decision"

[[ "$(rg -n 'Ok\(true\)' "$ORBIT_ROOT/$insecure_handler" | wc -l | tr -d ' ')" == "1" ]] || \
  fail "internal insecure handler must contain exactly one feature-gated Accept-All return"
head -n 1 "$ORBIT_ROOT/$insecure_handler" | \
  grep -Fqx '#![cfg(feature = "legacy-network-internal")]' || \
  fail "internal insecure handler lacks a file-level legacy-network-internal guard"
rg -q 'struct InsecureLegacyAcceptAllHostKeyHandler' "$ORBIT_ROOT/$insecure_handler" || \
  fail "internal handler type must be explicitly named insecure and legacy Accept-All"
grep -B1 -Fq 'pub(crate) mod insecure_legacy_host_key_handler;' \
  "$ORBIT_ROOT/orbit-core/src/security/mod.rs" || \
  fail "internal insecure handler module declaration is missing"
rg -q '#\[cfg\(feature = "legacy-network-internal"\)\]' \
  "$ORBIT_ROOT/orbit-core/src/security/mod.rs" || \
  fail "internal insecure handler module declaration is not feature-gated"

ok_true_files="$(rg -l 'Ok\(true\)' "$ORBIT_ROOT/orbit-core/src" --glob '*.rs' | sort)"
expected_ok_true_files="$(printf '%s\n%s\n' \
  "$ORBIT_ROOT/$checked_handler" "$ORBIT_ROOT/$insecure_handler" | sort)"
[[ "$ok_true_files" == "$expected_ok_true_files" ]] || {
  printf '%s\n' "$ok_true_files" >&2
  fail "an unallowlisted Rust Ok(true) return was added"
}

if rg -n 'insecure_legacy_host_key_handler|InsecureLegacyAcceptAllHostKeyHandler' \
  "${checked_rust_files[@]}"; then
  fail "checked Rust module references the insecure legacy handler"
fi
if rg -n 'OrbitSshClientHandler|impl[[:space:]]+client::Handler' \
  "$ORBIT_ROOT/orbit-core/src/lib.rs"; then
  fail "a production root module defines or references an unguarded SSH handler"
fi
rg -q '^default = \[\]$' "$ORBIT_ROOT/orbit-core/Cargo.toml" || \
  fail "Cargo default features must remain empty"
rg -q '^legacy-network-internal = \[\]$' "$ORBIT_ROOT/orbit-core/Cargo.toml" || \
  fail "explicit internal legacy feature is missing"
pass "public source has checked handler only; internal Accept-All is narrowly guarded"

section "Rust command-log redaction"
if rg -n '"[^"\n]*(command|stdout|stderr)[[:space:]]*=[[:space:]]*\{\}' \
  "$ORBIT_ROOT/orbit-core/src" --glob '*.rs'; then
  fail "Rust diagnostic formats a raw command or remote output"
fi
if rg -n '(println!|eprintln!|debug!|info!|warn!|error!)[^;]*(command|stdout|stderr)[[:space:]]*[,)]' \
  "$ORBIT_ROOT/orbit-core/src" --glob '*.rs' | \
  grep -v 'remote_exec_\(start\|finish\)_diagnostic'; then
  fail "Rust logging passes a raw command or remote output argument"
fi
if rg -n 'production_accept_all_handler|legacy_full_command_log' "$ALLOWLIST"; then
  fail "resolved A2.5d blockers must not remain allowlisted"
fi
pass "command diagnostics expose bounded metadata only"

section "Integration fixture secrets and paths"
if rg -n '^-----BEGIN (OPENSSH|RSA|EC) PRIVATE KEY-----$' "$ORBIT_ROOT" \
  --glob '!orbit-core/target/**' --glob '!build/**'; then
  fail "a private key appears to be committed; integration keys must be generated at runtime"
fi
if rg -n '(~[/]|[.]ssh/)known_hosts' \
  "$ORBIT_ROOT/orbit-core/src/security/openssh_integration_tests.rs" \
  "$SECURITY_SCRIPT_DIR/run_openssh_smoke.sh"; then
  fail "OpenSSH integration code references a user known_hosts path"
fi
rg -q 'run_openssh_smoke[.]sh' "$ORBIT_ROOT/docs/adr/ADR-032-openssh-integration-smoke-suite.md" || \
  fail "OpenSSH release-candidate script is missing from ADR-032"
pass "integration fixture commits no private key and avoids user known_hosts"

pass "Static security scans"
