# ADR-017: Docker Checked Typed API

- Status: Accepted for A4-Docker-2
- Date: 2026-06-21
- Scope: Checked Docker execution, additive C ABI, and typed rename/update preparation

## Context

ADR-016 closed direct parameter interpolation in Rust Docker action and logs
commands. That validator does not authenticate the SSH transport. Existing
Docker APIs still resolve a legacy SFTP session and execute through
`run_remote_command`, so they can use an Accept-All physical connection.

The Apple client also constructs `docker rename` and `docker update` strings
and sends them through the generic exec ABI. Those paths bypass the Rust
validator and remain a P0 injection risk until Swift migrates.

## Decision

Add a checked Docker coordinator whose production backend invokes only
`run_remote_command_checked`. Every operation:

1. accepts an opaque base-session ID rather than a host or SFTP session ID;
2. requires an Active `HostKeyVerified` base session;
3. rejects Legacy, Draining, Terminating, Closed, unknown, SFTP-like, and
   terminal-like IDs before backend execution;
4. revalidates the session generation around command execution;
5. constructs commands only from validated types;
6. never connects, reconnects, authenticates, triggers Host Key UI, waits for
   UI, or writes Known Hosts.

Checked Docker operations use a 12-second timeout, 1 MiB stdout limit, and 256
KiB stderr limit. Output, command text, credentials, Host Key material, and
Known Hosts paths are absent from Debug and error payloads.

## Rust API

The checked coordinator provides list, stats, logs, and action operations for
the additive ABI. List and stats use static commands and reuse the legacy pure
parsers so wire field semantics remain compatible. Logs and action use the
ADR-016 validator before a command can exist.

Rename and update are also implemented as Rust-only checked operations. Their
execution signatures accept `ValidatedContainerId`,
`ValidatedContainerName`, and `DockerUpdateOptions`, not raw strings. This
makes the validation boundary part of the type system and prepares safe client
migration without enlarging this patch's C surface.

## Additive C ABI

Add four versioned functions:

```c
char *orbit_docker_list_checked_v1(
    uint64_t base_session_id,
    const char *request_id
);
char *orbit_docker_stats_checked_v1(
    uint64_t base_session_id,
    const char *request_id
);
char *orbit_docker_logs_checked_v1(
    uint64_t base_session_id,
    const char *container_id,
    uint32_t tail,
    const char *request_id
);
char *orbit_docker_action_checked_v1(
    uint64_t base_session_id,
    const char *container_id,
    const char *action,
    const char *request_id
);
```

They never accept host, port, username, password, private key, passphrase, or
Known Hosts path. Rename and update remain Rust-only in this patch; dedicated
typed C functions or a strictly decoded update DTO can be added with Swift
migration.

All input strings are copied before asynchronous work. Returned JSON strings
are allocated by Rust and must be released with `orbit_free_string`. The
shared FFI response boundary catches panic and provides a JSON internal-error
fallback.

## JSON Protocol

Schema version 1 gains four additive kinds:

- `docker_containers`;
- `docker_stats`;
- `docker_logs`;
- `docker_action_result`.

Every payload contains `base_session_id` as a canonical decimal string and
the coarse `host_key_verified` security generation. This avoids integer
precision loss across language bridges and does not expose the fingerprint.
List/stats preserve the existing Docker item fields. Logs include bounded
remote log text. Action returns the validated canonical action and a
`completed` status, not raw command output.

Payloads contain no credentials, complete public key, Known Hosts path, or
command string. Error payloads never reflect submitted attack text.

## Typed Rename

Rename validates the old target as a 12-64 character hexadecimal container ID
and the new name with the independent grammar
`[A-Za-z0-9][A-Za-z0-9_.-]{0,127}`. Names beginning with punctuation,
containing slash, whitespace, controls, Unicode lookalikes, or shell syntax
are rejected. Only validated values can construct `docker rename`.

## Typed Update

Update accepts only these optional fields:

- restart policy: `no`, `always`, `unless-stopped`, or `on-failure`;
- memory limit: a positive canonical decimal plus optional `b`, `k`, `m`, or
  `g` suffix;
- CPU shares: `2..=262144`.

At least one field is required. Arbitrary flags, retry suffixes, whitespace,
shell syntax, and unsupported units fail closed. Command option order and CLI
tokens are fixed by Rust.

## Error Mapping

The protocol adds stable Docker codes for invalid container ID, invalid name,
invalid action, invalid logs tail, invalid update option, command failure, and
parse failure. Session gate and checked exec errors retain their existing
codes, including `legacy_session_not_allowed`, lifecycle states,
`exec_timeout`, and bounded-output failures.

Clients must branch on codes, never natural-language messages. Detailed
validation variants carry static reason codes but no submitted value.

## Legacy Compatibility

Legacy Docker ABI symbols and their `OK:/ERR:` behavior remain unchanged.
They still resolve a legacy SFTP session and are not a safe Release path. The
new checked functions are additive and do not alter SFTP, Monitor, batch,
ordinary SSH, checked SSH, or Host Key behavior.

## Swift Residual Risk and Migration

Swift is intentionally unchanged. `DockerService` still uses generic exec for
rename/update, so this patch does not claim those reachable client paths are
fixed. Migration must:

1. establish or reuse a checked SSH base session;
2. retain the verified base-session ID;
3. call checked list/stats/logs/action functions;
4. replace generic rename/update strings with typed Rust entry points;
5. stop Docker activity on challenge, blocked, lifecycle, or generation
   errors;
6. never silently reconnect through legacy SFTP.

Apple CBridge Header synchronization remains part of that client patch.

## Release Gate

Release must disable or redirect legacy Docker networking and the generic
Docker rename/update path after migration. CI must prove that checked Docker
rejects Legacy and non-Active sessions and that old ABI cannot provide an
Accept-All release bypass. A remote feature flag must never re-enable legacy
transport in Release.

## Testing

Tests use synthetic base sessions and injected checked-exec backends. They
cover verified success; Legacy/lifecycle/unknown/untyped ID rejection before
execution; exact static and validated commands; typed rename/update; malicious
input rejection; parse/exec error separation; JSON round trips; request-ID and
UTF-8 validation; string session IDs; redaction; C string release; header
preservation; and stable error codes. Default tests require no SSH or Docker
service.

## Rollback

Rollback removes only the new checked coordinator, four additive symbols,
protocol variants, tests, and header declarations. Legacy behavior remains
unchanged. Rollback is a development option, not a Release fallback: shipping
must not return Docker to Accept-All transport or raw generic command
construction.
