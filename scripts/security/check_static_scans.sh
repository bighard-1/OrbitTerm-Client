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

section "Swift runtime-log privacy defaults"
if rg -n --glob '*.swift' 'logger[.](debug|info|notice|error)[(].*privacy:[[:space:]]*[.]public' "$ORBIT_ROOT/OrbitTerm"; then
  fail "runtime logging exposes interpolated fields as public"
fi
if rg -n --glob '*.swift' 'DiagnosticsManager[.]shared[.]record\([^\n]*error[.]localizedDescription' "$ORBIT_ROOT/OrbitTerm"; then
  fail "diagnostics receive a raw localized error"
fi
if rg -n 'localizedDescription' "$ORBIT_ROOT/OrbitTerm/Features/Home/DiagnosticsExportView.swift"; then
  fail "diagnostic export UI exposes a raw file-system error"
fi
rg -q 'DiagnosticExportFilePolicy' "$ORBIT_ROOT/OrbitTerm/Core/DiagnosticsManager.swift" || \
  fail "diagnostic export lacks the reviewed managed-file policy"
rg -q 'override func copy' "$ORBIT_ROOT/OrbitTerm/Features/Home/SwiftTermPlatformSupport.swift" || \
  fail "macOS terminal copy does not route through the central clipboard policy"
rg -Fq 'SecureClipboard.copy(data, kind: .terminalOutput)' \
  "$ORBIT_ROOT/OrbitTerm/Features/Home/SwiftTermPlatformSupport.swift" || \
  fail "macOS terminal context-menu copy bypasses expiry policy"
if rg -n 'localizedDescription' \
  "$ORBIT_ROOT/OrbitTerm/Features/Home/AssetQuickKeySetupSheet.swift" \
  "$ORBIT_ROOT/OrbitTerm/Features/Home/AddServerView.swift"; then
  fail "private-key UI exposes a raw file-system or process error"
fi
pass "runtime logs default to private and diagnostics avoid raw errors"

section "Mock, demo, and UI-test release confinement"
ui_test_state="$ORBIT_ROOT/OrbitTerm/Core/AppUITestLaunchState.swift"
sftp_mock="$ORBIT_ROOT/OrbitTerm/Core/SFTPManager+Mock.swift"
sftp_connection="$ORBIT_ROOT/OrbitTerm/Core/SFTPManager+Connection.swift"
sftp_panel="$ORBIT_ROOT/OrbitTerm/Features/Home/SFTPBrowserPanels.swift"

rg -q '#if !ORBITTERM_PUBLIC_RELEASE' "$ui_test_state" || fail "UI-test launch state is not non-Release confined"
rg -q 'contains\("-orbitTermUITest"\)' "$ui_test_state" || fail "UI-test launch state lacks an explicit test-process marker"
rg -q '#if !ORBITTERM_PUBLIC_RELEASE' "$sftp_mock" || fail "SFTP mock directory fixture is not non-Release confined"
rg -q '#if !ORBITTERM_PUBLIC_RELEASE' "$sftp_connection" || fail "SFTP mock activation is not non-Release confined"
rg -q '#if !ORBITTERM_PUBLIC_RELEASE' "$sftp_panel" || fail "SFTP mock UI is not non-Release confined"
if rg -n '模拟模式|模拟目录|进入模拟浏览|Mock 文件列表' \
  "$ORBIT_ROOT/OrbitTerm/Features" | rg -v 'SFTPBrowser(Panels|View)[.]swift'; then
  fail "mock presentation escaped the dedicated development panel"
fi
pass "mock data and UI-test launch fixtures are release confined"

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
pass "Swift dangerous legacy calls are compile guarded"

section "Swift Telnet explicit opt-in isolation"
if rg -n 'ConnectionSecurityPolicy[.]allowsTelnet' \
  "$ORBIT_ROOT/OrbitTerm" "$ORBIT_ROOT/OrbitTermCheckedFFITests"; then
  fail "Telnet still depends on the legacy-network policy or legacy default-on preference"
fi
if rg -n 'orbitterm[.]enable[.]telnet' "$ORBIT_ROOT/OrbitTerm"; then
  fail "production code still reads the legacy default-on Telnet preference"
fi
telnet_construction_files="$(rg -l 'TelnetClient[[:space:]]*[(]' "$ORBIT_ROOT/OrbitTerm" --glob '*.swift' | sort)"
expected_telnet_construction_files="$(printf '%s\n%s\n' \
  "$ORBIT_ROOT/OrbitTerm/Core/SessionManager.swift" \
  "$ORBIT_ROOT/OrbitTerm/Features/Home/AddServerConnectionTester.swift" | sort)"
[[ "$telnet_construction_files" == "$expected_telnet_construction_files" ]] || {
  printf '%s\n' "$telnet_construction_files" >&2
  fail "Telnet connection construction escaped its reviewed entry points"
}
rg -q 'switch telnetAccessPolicy[.]decision' "$ORBIT_ROOT/OrbitTerm/Core/SessionManager.swift" || \
  fail "SessionManager does not gate Telnet through the explicit opt-in policy"
rg -q 'case [.]requiresConfirmation:' "$ORBIT_ROOT/OrbitTerm/Core/SessionManager.swift" || \
  fail "SessionManager does not require per-target Telnet confirmation"
rg -q 'func disableTelnetAndDisconnect' "$ORBIT_ROOT/OrbitTerm/Core/SessionManager.swift" || \
  fail "disabling Telnet does not close active sessions"
rg -q 'static let enabledStorageKey = "orbitterm[.]telnet[.]explicit[.]enabled[.]v2"' \
  "$ORBIT_ROOT/OrbitTerm/Core/TelnetAccessPolicy.swift" || \
  fail "Telnet does not use the reviewed fail-closed preference key"
rg -q '@AppStorage[(]TelnetAccessPolicy[.]enabledStorageKey[)] private var telnetEnabled: Bool = false' \
  "$ORBIT_ROOT/OrbitTerm/Features/Home/SettingsView.swift" || \
  fail "Settings does not default Telnet to disabled"
if rg -n 'fallback.*[Tt]elnet|[Tt]elnet.*fallback' "$ORBIT_ROOT/OrbitTerm" --glob '*.swift'; then
  fail "SSH or another service appears to fall back to Telnet"
fi
pass "Telnet is locally opt-in, per-target confirmed, and isolated from legacy SSH"

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
keyboard_auth_session="orbit-core/src/ssh_session.rs"
grep -Fqx "checked_trusted_proceed|$checked_handler|HostKeyVerificationDecision::Proceed" \
  "$STATIC_SCAN_ALLOWLIST" || fail "checked trusted-proceed exception is missing or too broad"
grep -Fqx "internal_legacy_accept_all|$insecure_handler|legacy-network-internal" \
  "$STATIC_SCAN_ALLOWLIST" || fail "internal legacy handler exception is missing or too broad"
grep -Fqx "keyboard_interactive_auth_success|$keyboard_auth_session|KeyboardInteractiveAuthResponse::Success => return Ok(true)" \
  "$STATIC_SCAN_ALLOWLIST" || fail "keyboard-interactive authentication exception is missing or too broad"

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

[[ "$(rg -n 'KeyboardInteractiveAuthResponse::Success[[:space:]]*=>[[:space:]]*return Ok\(true\)' \
  "$ORBIT_ROOT/$keyboard_auth_session" | wc -l | tr -d ' ')" == "1" ]] || \
  fail "keyboard-interactive authentication success must remain a single explicit branch"

ok_true_files="$(rg -l 'Ok\(true\)' "$ORBIT_ROOT/orbit-core/src" --glob '*.rs' | \
  grep -Fvx "$ORBIT_ROOT/$keyboard_auth_session" | sort)"
expected_ok_true_files="$(printf '%s\n%s\n' \
  "$ORBIT_ROOT/$checked_handler" "$ORBIT_ROOT/$insecure_handler" | sort)"
[[ "$ok_true_files" == "$expected_ok_true_files" ]] || {
  printf '%s\n' "$ok_true_files" >&2
  fail "an unallowlisted Rust Host Key Ok(true) return was added"
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
