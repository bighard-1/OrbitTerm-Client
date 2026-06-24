# ADR-020: Checked Terminal PTY C ABI

- Status: Accepted for A2.3e-Terminal
- Date: 2026-06-22
- Scope: Additive checked terminal channel opening on a verified base session

## Context

The Rust Core can establish a reusable `HostKeyVerified` SSH base session and
can open checked SFTP, Monitor, and Docker channels from it. The Apple-side
Host Key trust coordinator and UI skeleton are also available, but Terminal
migration remains unsafe without a checked PTY entry point.

The existing `orbit_request_channel(session_or_channel_id, "pty")` accepts a
mixed integer namespace. Its resolver probes base sessions, SFTP sessions, and
terminal channels, then opens a PTY without requiring
`SessionSecurityGeneration::HostKeyVerified`. It must remain unchanged for
compatibility, but it cannot be used by a Release checked path.

## Decision

Add the following versioned, additive C ABI:

```c
char *orbit_terminal_open_checked_v1(
    uint64_t base_session_id,
    uint32_t cols,
    uint32_t rows,
    const char *request_id
);
```

The function accepts only an opaque base-session ID, checked PTY dimensions,
and a correlation ID. It accepts no host, username, password, private key,
passphrase, token, or Known Hosts path.

The Rust entry point performs these steps:

1. validate the request ID and PTY size;
2. resolve only the tagged base-session namespace;
3. require an Active `HostKeyVerified` session;
4. revalidate the pinned security generation;
5. open an SSH session channel on that existing physical connection;
6. request an `xterm-256color` PTY;
7. request a shell;
8. revalidate immediately before registration;
9. register terminal metadata and return its opaque channel ID.

There is no legacy fallback. The operation does not perform TCP connection,
KEX, authentication, Host Key UI, Known Hosts writes, reconnection, or UI
waiting.

## Base-Only Resolution and Verified Gate

The checked function calls `require_active_verified_base_session`, which uses
`resolve_base_session_by_base_id`. It never calls the legacy mixed resolver.
Consequently SFTP IDs, terminal IDs, arbitrary low integers, unknown base IDs,
and stale IDs cannot be interpreted as a base session.

`LegacyUnverified`, Draining, Terminating, and Closed sessions fail before the
channel backend runs. A security-generation mismatch also fails closed. The
guard is revalidated around asynchronous channel setup so a lifecycle change
cannot publish a new checked terminal channel.

## PTY Size Validation

The checked API accepts `cols` and `rows` only in `1..=1000`. Zero and larger
values return `invalid_pty_size`. Validation is checked-only: the old generic
PTY path retains its existing fixed `120x36` behavior and error semantics.

## Terminal Metadata

Every registered terminal channel now carries internal metadata:

- base-session ID;
- `SessionSecurityGeneration`;
- creation time;
- source (`Checked` or `Legacy`);
- initial columns and rows.

Checked metadata is derived only from `VerifiedBaseSessionGuard`. Its Debug
implementation redacts the complete security generation and therefore cannot
expose fingerprint, full public key, trust-store contents, local path, or
credentials. Existing read, write, resize, close, callback, and base-reference
lifecycle behavior remains unchanged. Metadata prepares later channel-use
revalidation without changing those legacy operations in this patch.

## JSON Result

Success uses schema version 1 and kind `terminal_channel_opened`:

```json
{
  "base_session_id": "281474976710657",
  "terminal_channel_id": "1",
  "security_generation": "host_key_verified",
  "cols": 120,
  "rows": 32
}
```

Both IDs are canonical nonzero decimal strings. String representation avoids
`u64` precision loss in Swift, JavaScript, and future bridges. The security
generation is intentionally coarse and contains no fingerprint or public key.

## Error Mapping

Existing session and channel codes are reused:

- `session_not_found`;
- `legacy_session_not_allowed`;
- `verified_session_required`;
- `security_generation_mismatch`;
- `session_draining`;
- `session_terminating`;
- `session_closed`;
- `channel_open_failed`.

PTY-specific stable codes are:

- `invalid_pty_size`;
- `pty_request_failed`;
- `shell_start_failed`.

An internal terminal-map registration failure returns `ffi_internal_error`
with a stable detail code. No error includes a remote error string, complete
key, local path, command, or credential.

## C String Ownership and Panic Boundary

The request ID is borrowed only during the call and copied into Rust-owned
memory before asynchronous work. No caller pointer is retained. Every return
value is a Rust-allocated NUL-terminated JSON string and must be released with
`orbit_free_string`.

The shared `ffi_response` boundary catches unwind and converts it to a JSON
internal error. The success envelope is serialization-preflighted before the
terminal ID is published. If this post-open step fails, Rust best-effort closes
the new terminal channel so it is not leaked.

## Legacy Compatibility

`orbit_request_channel`, `orbit_terminal_write`, `orbit_terminal_resize`,
`orbit_terminal_close`, and the terminal callback ABI retain their signatures
and behavior. The old generic resolver and PTY path remain available for
staged Debug/Internal migration.

This compatibility is not a Release policy. The generic unchecked PTY path
must be made unreachable or fail closed before production release.

## Apple Migration

Swift is intentionally unchanged. The next SessionManager migration can:

1. complete checked SSH connect through `HostKeyTrustCoordinator`;
2. retain the typed verified base-session ID;
3. call `orbit_terminal_open_checked_v1` with a fresh request ID;
4. decode `terminal_channel_opened` and retain a typed terminal channel ID;
5. use the existing write, resize, read-callback, and close operations;
6. never fall back to generic `orbit_request_channel("pty")` after a checked
   failure.

## Testing

Network-independent tests use synthetic base sessions and an injected terminal
backend. They cover Active verified success, base-only namespace rejection,
Legacy and lifecycle rejection before backend use, size boundaries, channel,
PTY, shell, and registration errors, checked metadata, redacted Debug output,
request-ID validation, JSON string IDs, payload validation, Rust string
release, header preservation, and stable error codes.

Build verification additionally checks strict C11 header syntax and old/new
dynamic-library symbols.

## Rollback

Rollback removes only the checked terminal module, `_v1` symbol, result kind,
PTY-specific error codes, metadata additions, tests, and canonical header
declaration. It does not alter existing sessions, Known Hosts data, or legacy
symbols.

Rollback is a development option only. Production must not fall back to the
unchecked generic PTY path.
