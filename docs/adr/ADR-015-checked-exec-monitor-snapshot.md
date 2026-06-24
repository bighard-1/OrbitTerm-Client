# ADR-015: Checked Exec and Monitor Snapshot

- Status: Accepted for A2.3e-4
- Date: 2026-06-21
- Scope: Verified-session exec primitive and additive one-shot Monitor C ABI

## Context

A2.3e-3 exposed checked SFTP from an Active `HostKeyVerified` base session.
Monitor remained a Critical bypass because the existing Apple flow obtains an
SFTP session through legacy connection APIs and the Rust monitor opens exec
channels directly from that base.

The existing `run_remote_command` has no security-generation gate, timeout, or
output bound. It logs the complete command in debug mode and embeds command and
stderr text in errors. Existing Monitor sampling executes six commands and
uses `unwrap_or_default`, which can turn transport and Host Key state failures
into plausible all-zero metrics.

Changing those functions would affect Docker, batch command, SFTP helper
operations, and current clients. This patch therefore adds a parallel checked
primitive and a one-shot Monitor ABI while preserving all legacy behavior.

## Decision

Add `run_remote_command_checked(base_session_id, command, options)` as the only
exec primitive used by checked Monitor. It:

- resolves only the base-session namespace;
- requires Active `HostKeyVerified` metadata;
- revalidates the exact generation before opening and after consuming output;
- opens one exec channel on the existing physical SSH connection;
- never accepts host, port, username, password, private key, token, or Known
  Hosts path;
- never performs KEX, physical connection creation, reconnection, Host Key UI,
  or Known Hosts writes.

SFTP and terminal IDs are not accepted as base IDs and never reach the channel
backend.

## Checked Exec Resource Policy

Monitor commands use checked-only defaults:

- 5-second timeout per complete channel operation;
- 256 KiB maximum stdout;
- 256 KiB maximum stderr;
- 16 KiB maximum command text;
- strict UTF-8 output;
- mandatory exit status and zero exit code.

The timeout includes channel open, exec request, and output collection. Output
growth uses checked arithmetic. Limit, decoding, premature-close, request,
timeout, and nonzero-exit failures remain distinct structured states.

No error or Debug representation includes the command, stdout, or stderr.
Remote output may contain credentials or tokens even when the command itself
is static, so it is treated as sensitive diagnostic material.

These bounds close the immediate unbounded-resource path for checked Monitor
without changing legacy behavior. They remain a P0 tuning item: later checked
Docker and batch commands may need command-specific limits, cancellation, and
streaming rather than reusing Monitor defaults.

## Monitor Snapshot

Add `fetch_system_stats_checked(base_session_id)`. It creates one snapshot and
does not start polling or retain a task. It runs the same six Linux-oriented
commands as the legacy monitor, but every command goes through the checked exec
primitive:

1. top CPU summary;
2. `/proc/stat` CPU fallback data;
3. `free` memory summary;
4. `/proc/meminfo` memory fallback data;
5. root filesystem usage;
6. `/proc/net/dev` counters.

The base gate is also rechecked around every backend call and before/after the
local ping probe. Any gate or exec failure aborts the snapshot. CPU, memory,
disk, or network parse failure returns `monitor_snapshot_failed` rather than a
silent zero. Ping is explicitly noncritical: failure produces `null` latency
and the stable `ping_unavailable` diagnostic.

The existing per-base network snapshot remains the source for rate deltas. No
host or credential is retained for reconnection.

## C ABI

Add the versioned, additive function:

```c
char *orbit_monitor_snapshot_checked_v1(
    uint64_t base_session_id,
    const char *request_id
);
```

It accepts only a checked base ID and correlation ID. It is a synchronous thin
wrapper over the existing runtime and one-shot checked snapshot. It never
creates a physical connection, triggers Host Key UI, waits for UI, reconnects,
or schedules long-running polling.

## JSON Result

Success uses schema version 1 and kind `monitor_snapshot`. Data contains:

- `base_session_id` as a canonical decimal string;
- coarse `host_key_verified` security generation;
- stats matching the existing Monitor metric names;
- bounded stable diagnostic codes.

The ID follows checked SFTP's string strategy and therefore cannot lose `u64`
precision in JavaScript or Swift bridges. Stats contain no fingerprint,
complete public key, credentials, Known Hosts path, command, stdout, or stderr.

## Error Mapping

Session gate errors retain the existing codes. Checked exec adds:

- `exec_request_failed`;
- `exec_output_failed`;
- `exec_timeout`;
- `exec_command_failed`.

Metric parsing uses `monitor_snapshot_failed`. Internal option or invariant
failures use `ffi_internal_error`. Error payloads carry only stable code,
detail code, retryability, and request correlation; clients do not parse
natural-language SSH errors.

## C String Ownership

The request ID is copied from the borrowed C string before asynchronous work.
Rust stores no caller pointer. Returned JSON is Rust-allocated and must be
released with `orbit_free_string`.

The shared `ffi_response` boundary catches unwind and emits a JSON internal
error fallback if envelope serialization fails. No panic may cross C.

## Legacy Compatibility

`orbit_fetch_system_stats`, legacy SFTP, legacy exec, Docker, and batch-command
functions are unchanged. The old monitor continues accepting an SFTP session
ID, preserves its error swallowing and output behavior, and remains available
for staged Debug/Internal migration.

This compatibility is not a Release policy. Legacy Monitor networking must be
disabled or redirected after clients migrate.

## Client Migration

Swift is intentionally unchanged. A later client patch must:

1. establish or reuse a checked SSH base session;
2. retain its opaque base-session ID;
3. schedule polling in Swift;
4. call `orbit_monitor_snapshot_checked_v1` once per interval;
5. stop polling on lifecycle, Host Key, or session errors;
6. never silently reconnect through legacy SFTP.

Unknown, Changed, and Revoked handling remains owned by the checked connect/UI
flow, not Monitor.

## Non-Goals

This patch does not modify Swift, Android, Go, old Monitor, old SFTP, ordinary
SSH, checked connect, checked SFTP, or the production accept-all Handler. It
does not migrate Docker or batch command, validate Docker arguments, add
ProxyJump, alter RSA policy, write Known Hosts, or add UI.

## Testing

Tests use synthetic base sessions and injected exec/monitor backends. They
cover Active verified success, base-only ID resolution, Legacy and lifecycle
rejection before backend use, channel/request/output/timeout/nonzero failures,
all six Monitor commands, parsing, ping diagnostics, JSON round-trip and
redaction, request-ID validation, C string release, header preservation, and
stable error codes.

Default tests require no external SSH server. Build verification additionally
checks strict C11 header syntax and old/new dynamic-library symbols.

## Rollback

Rollback removes the checked exec and Monitor modules, the new result kind and
error codes, the `_v1` symbol, tests, and header declaration. It does not alter
Known Hosts, session IDs, existing network connections, or legacy symbols.

Rollback remains a development boundary only. Release must not fall back to
legacy Monitor or accept-all SSH.

## Follow-up

Docker command validation should be addressed as an independent P0 before its
checked migration because checked transport does not make shell interpolation
safe. After validation, Docker can reuse checked exec with command-specific
bounds. Batch command requires a separate multi-host challenge and execution
design and should follow the validator work.
