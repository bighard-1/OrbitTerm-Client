# ADR-027: Batch Checked Command Migration

## Status

Accepted for the A2.4h migration stage.

## Context

SFTP, Monitor, and Docker now have checked Swift service paths that operate from a verified `BaseSessionID`. Batch command execution remained a critical bypass because the Swift UI read credentials, opened legacy SSH/SFTP-oriented command paths, and executed commands without requiring the HostKeyVerified base-session gate.

Rust now exposes `orbit_exec_checked_v1`, an additive checked exec ABI that accepts only `base_session_id`, a bounded single command, execution limits, and `request_id`. It calls the Rust checked exec primitive and therefore requires an active HostKeyVerified base session.

## Decision

Swift Batch checked mode uses `execChecked` over `orbit_exec_checked_v1`. It does not call legacy SFTP connect, legacy exec, or generic request-channel paths. The checked Batch path only executes against targets that already have a verified workspace session in `SessionManager`.

Targets without a verified workspace session fail closed as `requiresVerifiedSession`. This is the intentional minimum migration for A2.4h. Full per-target Host Key preflight UI remains a follow-up because it needs a multi-host challenge aggregation design and must not introduce a `Trust All` shortcut.

## Checked Adapter

`OrbitCoreCheckedFFIClient.execChecked` calls `orbit_exec_checked_v1` and decodes the `exec_result` JSON envelope. It validates request correlation and base-session correlation before returning `ExecResultPayload`.

The adapter does not fallback to `orbit_exec_command`, `orbit_sftp_connect`, or `orbit_request_channel`.

During the Apple migration window, the live Swift function table resolves `orbit_exec_checked_v1` dynamically so app targets can still build while local prebuilt orbit-core artifacts are refreshed. If the symbol is absent at runtime, the adapter receives a null C result and fails closed through the structured checked-client error path; it does not call any legacy ABI.

## Command Validation

Batch is a user-authorized command execution feature, so it does not use a Docker-style command allowlist. Shell metacharacters remain allowed because they are part of the explicit Batch command semantics.

Swift validates the command before crossing the FFI boundary:

- non-empty after trimming whitespace and newlines;
- maximum 16 KiB UTF-8;
- no NUL;
- no tab;
- no newline or carriage return;
- no other control characters.

Checked v1 intentionally does not support multiline commands. Legacy mode keeps its existing behavior during the migration window.

## Execution Limits

Swift uses the checked exec v1 defaults:

- timeout: 30 seconds;
- stdout max: 256 KiB;
- stderr max: 64 KiB.

The Swift option type enforces the Rust v1 maximums: 300 seconds timeout, 1 MiB stdout, and 256 KiB stderr.

## Per-target State

Checked Batch uses a strong per-target state model:

- `pending`;
- `requiresVerifiedSession`;
- `awaitingHostKeyDecision`;
- `blocked`;
- `running`;
- `succeeded`;
- `failed`;
- `cancelled`.

In this stage, unverified targets go directly to `requiresVerifiedSession`. Unknown / Changed / Revoked aggregation is deferred to the full preflight UI stage. Changed and Revoked targets must never execute commands.

## Verified Base Handoff

Batch obtains verified base sessions from `SessionManager` / `WorkspaceSession.verifiedSessionLease`. It does not infer base sessions from SFTP IDs, terminal channel IDs, or mixed integer namespaces.

## No Trust All

Batch may target multiple hosts, but this migration does not add any `Trust All` affordance. Multi-host trust decisions must remain per-host and explicit.

## Error Handling

Errors are structured through `CheckedBatchCommandError` and checked FFI error codes. Natural language messages are only presentation text. Debug descriptions do not include full commands, stdout, stderr, credentials, or known-hosts paths.

Non-zero command exit status is represented as a per-target command failure with the bounded stdout/stderr available for the result UI.

## Legacy Mode

Legacy Batch behavior remains unchanged when checked migration mode is disabled. In checked mode, failure never falls back to legacy execution.

## Testing

Tests cover:

- `exec_result` DTO decoding;
- `execChecked` adapter kind/request/base-session validation;
- command validation boundaries;
- verified target execution;
- unverified target fail-closed;
- per-target unique request IDs;
- cancellation / late response handling;
- no checked connect or SFTP calls from Batch checked service;
- redacted debug descriptions.

## Follow-ups

- Build full multi-target checked Host Key preflight UI.
- Add Release Gate to fail closed legacy networking symbols in release builds.
- Remove production Accept-All host-key behavior.
- Optionally add Docker rename/update checked C ABI; current checked mode disables those actions.

## Rollback

The change is guarded by the existing Debug/Internal checked migration mode. Rollback is to disable the checked mode or remove the checked Batch service wiring while leaving the additive Swift DTO and adapter code inert.
