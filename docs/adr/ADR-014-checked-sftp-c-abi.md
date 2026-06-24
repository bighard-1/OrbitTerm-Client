# ADR-014: Checked SFTP C ABI

- Status: Accepted for A2.3e-3
- Date: 2026-06-21
- Scope: Additive JSON C ABI for opening SFTP from a verified base session

## Context

A2.3e-2 added a Rust Core SFTP path that resolves only base-session IDs,
requires an Active `HostKeyVerified` security generation, opens the SFTP
subsystem, and records checked SFTP metadata. Apple and other C consumers still
need a stable ABI to invoke that path without falling back to the legacy
credential-based `orbit_sftp_connect` function.

The legacy function can establish a `LegacyUnverified` physical SSH connection
and therefore remains a release-blocking bypass. This patch adds a migration
surface without changing or deleting the legacy ABI.

## Decision

Add the following versioned, additive C ABI:

```c
char *orbit_sftp_open_checked_v1(
    uint64_t base_session_id,
    const char *request_id
);
```

It accepts only an opaque base-session ID returned by checked SSH connect and a
correlation request ID. It does not accept host, port, username, password,
private key, passphrase, token, or Known Hosts path.

The implementation is a thin adapter over `open_sftp_channel_checked`. It
cannot create a physical SSH connection and has no fallback to
`orbit_sftp_connect`.

## Flow

1. Copy and validate `request_id` from the borrowed C string.
2. Reject a zero base-session ID as `invalid_request`.
3. Call `open_sftp_channel_checked(base_session_id)` on the existing runtime.
4. Resolve only the base-session namespace.
5. Require Active `HostKeyVerified` metadata.
6. Open an SSH session channel on the existing verified transport.
7. Request the `sftp` subsystem and register checked SFTP metadata.
8. Return `sftp_channel_opened` in the schema-version-1 JSON envelope.

Legacy, Draining, Terminating, Closed, unknown, or generation-invalid sessions
fail closed before a usable SFTP ID is returned.

The response envelope is serialization-preflighted before its ID is published
to C. If that post-open protocol step fails, Rust removes the checked SFTP
entry, best-effort closes it, and releases its base-session reference.

## No Host Key UI or Physical Connection

The ABI does not perform KEX or Host Key verification itself. Those operations
must already have succeeded in `orbit_ssh_connect_checked_v1`, which produced
the verified base-session ID. Consequently this call never registers a Host
Key challenge, displays UI, waits for UI, or retains a half-open authentication
connection.

If no verified base session exists, the caller must start the checked SSH flow
first. SFTP must not silently trigger credential-based connection creation.

## JSON Result

Success uses kind `sftp_channel_opened` with:

```json
{
  "base_session_id": "281474976710657",
  "sftp_session_id": "1",
  "security_generation": "host_key_verified"
}
```

Both IDs are decimal strings. Current base IDs are namespace-tagged below the
JavaScript safe-integer limit, but SFTP IDs are modeled as `u64`. String form
preserves exact values across JavaScript, Swift, C, and future transports and
keeps both ID fields consistent. Values must be canonical nonzero decimal
representations without leading zeroes.

The security-generation field is intentionally coarse. It confirms the gate
class without exposing fingerprint, complete public key, trust-store content,
or local path.

## Error Mapping

`CheckedChannelAccessError` maps directly to stable protocol codes:

- `session_not_found`;
- `legacy_session_not_allowed`;
- `verified_session_required`;
- `security_generation_mismatch`;
- `session_draining`;
- `session_terminating`;
- `session_closed`;
- `channel_open_failed`;
- `subsystem_request_failed`;
- `sftp_registration_failed`;
- `ffi_internal_error` for internal invariants.

Null, malformed, oversized, or unsafe request IDs return `invalid_request` or
`invalid_utf8`. No error depends on parsing natural-language text.

## C String Ownership and Panic Boundary

Input strings are borrowed only for the duration of the call and copied before
asynchronous work. Rust never stores the caller's pointer. Every non-null
result is a Rust-allocated NUL-terminated JSON string and must be released with
`orbit_free_string`.

The shared `ffi_response` boundary catches unwind, serializes all failures as
JSON, and falls back to a static-shape internal-error document if serialization
itself fails. No Rust panic may unwind across C.

## Legacy ABI

`orbit_sftp_connect` and all existing list, upload, download, read, write,
rename, delete, mkdir, stat, chmod, and disconnect signatures and behavior are
unchanged. This is a compatibility boundary for Debug/Internal migration, not
permission to ship legacy SFTP networking in Release.

## Client Migration

Swift is intentionally unchanged in this patch. The later Apple integration
must synchronize the bridge header and use:

```text
checked SSH connect
-> decode verified base session ID
-> orbit_sftp_open_checked_v1(base_session_id, request_id)
-> decode SFTP session ID
-> existing SFTP operations
```

The client must correlate responses by request ID and must not retry through
legacy `orbit_sftp_connect` after any checked error.

## Release Gate

After Swift and other clients migrate, Release builds must prevent legacy SFTP
from establishing network connections. A remote configuration must not be able
to re-enable it. CI must prove that checked SFTP rejects legacy sessions and
that old ABI symbols either fail closed or are unavailable under the final
Release policy.

## Testing

Tests cover null, invalid UTF-8, oversized, control-character, zero, and unknown
inputs; Active verified success; Legacy and lifecycle-state rejection; channel,
subsystem, registration, generation, and internal errors; request-ID round
trip; string ID precision; payload validation; redaction; C header preservation;
and Rust-owned string release.

The success wrapper uses an injected test opener, while the exported production
symbol is hard-wired to `open_sftp_channel_checked`. Lifecycle failures call
the exported function and therefore exercise the real verified gate without an
external SSH service. Default tests remain network-independent.

Build verification also checks strict C11 header syntax and the exported
dynamic-library symbol.

## Rollback

Rollback removes only the new `_v1` symbol, its DTO/result kind, thin wrapper,
tests, and header declaration. It does not migrate or delete Known Hosts data,
base sessions, SFTP state, or legacy symbols.

Rollback is available during staged development. It is not an acceptable
Release fallback to unchecked SFTP.

## Follow-up

A2.3e-4 should design and implement a checked remote-exec primitive over the
same verified base-session gate, then use it for Monitor snapshots. Docker and
batch-command paths remain separate Critical bypasses and require their own
checked migration before the final Release gate.
