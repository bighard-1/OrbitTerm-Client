# ADR-026: Checked Exec C ABI for Batch

## Status

Accepted.

## Context

Swift SFTP, Monitor, and Docker now have checked service paths backed by an
`Active + HostKeyVerified` base session. Batch remains a release blocker: its
current Swift path creates a legacy SFTP session and sends commands through the
legacy generic exec ABI.

Rust already has `run_remote_command_checked`. It resolves only a typed base
session, applies the verified channel gate, opens a checked exec channel, and
bounds time, stdout, and stderr. Swift could not use it because no C ABI exposed
the primitive.

## Decision

Add the following additive ABI:

```c
char *orbit_exec_checked_v1(
    uint64_t base_session_id,
    const char *command,
    uint32_t timeout_seconds,
    uint32_t max_stdout_bytes,
    uint32_t max_stderr_bytes,
    const char *request_id
);
```

The function accepts no host, username, credential, private key, token, or
known-hosts path. It never creates a physical SSH connection, waits for UI, or
falls back to `orbit_exec_command`. It calls `run_remote_command_checked`, so
legacy, mismatched, draining, terminating, closed, SFTP, terminal, and unknown
session IDs fail closed before channel execution.

## Command policy

Batch is an explicit arbitrary-shell-command feature. Therefore the checked
exec API does not apply a Docker-style command allowlist and does not remove
shell metacharacters. Shell syntax is part of the user-authorized command.

The boundary does enforce protocol limits:

- command must contain non-whitespace text;
- UTF-8 length must not exceed 16 KiB;
- NUL and all control characters are rejected;
- newlines and tabs are rejected in v1;
- the command is copied during the call and never stored or logged.

Multiline Batch commands require a later explicit protocol design. This policy
is a resource and ambiguity boundary, not a shell-injection defense.

## Timeout and output limits

Zero option values select safe defaults:

- timeout: 30 seconds;
- stdout: 256 KiB;
- stderr: 64 KiB.

Maximum accepted values are 300 seconds, 1 MiB stdout, and 256 KiB stderr.
Values above those maxima return `invalid_exec_options`. The checked primitive
uses bounded vectors and fails with `exec_output_limit_exceeded`; it does not
return partial output. Successful payloads therefore set both truncation flags
to `false`.

## Result semantics

Success returns the `exec_result` JSON kind with a decimal-string base session
ID, `host_key_verified`, exit status, bounded stdout/stderr, and explicit
timeout/truncation flags. The current primitive treats a nonzero exit status as
`exec_command_failed`; only exit status zero produces `exec_result`.

Error envelopes use stable codes for invalid command, oversized command,
invalid options, channel open, exec request/output, output limit, timeout,
nonzero exit, session gate failures, UTF-8, request validation, and internal
failure. Errors never echo the command or include credentials, public keys, or
local paths. `ExecResultPayload` also redacts stdout and stderr from `Debug`.

## C ownership and panic boundary

The returned Rust-owned C string follows the existing ownership model and must
be released with `orbit_free_string`. Input pointers are borrowed only long
enough to copy their values. The shared `ffi_response` boundary catches panics
and returns `ffi_internal_error` rather than unwinding across C.

## Compatibility

The legacy `orbit_exec_command(uint64_t session_id, const char *command)` symbol
and behavior remain unchanged. Keeping it is temporary compatibility, not a
release-safe fallback. This patch does not modify Swift or migrate Batch UI.

## Follow-up

Swift Batch migration must:

1. obtain a verified base session from SessionManager;
2. call only `orbit_exec_checked_v1` with a fresh request ID per host;
3. aggregate connected, challenge, blocked, and execution outcomes without
   Trust All;
4. never open legacy SFTP or invoke legacy generic exec;
5. stop on cancellation or session-gate failure.

The Release gate must subsequently prove that Batch and all other Release paths
cannot reach Accept-All or legacy exec networking.

## Testing

Tests cover base-only verified gating, lifecycle states, non-base IDs, command
and request validation, defaults and maxima, bounded output, every stable error
mapping, nonzero exit behavior, panic containment, JSON ownership and
redaction, Header preservation, and protocol round trips. External SSH is not
required by default tests.

## Rollback

Remove the additive export, protocol kind/payload/error additions, Header
declaration, and dedicated tests. No legacy ABI or existing checked feature
needs to change during rollback.
