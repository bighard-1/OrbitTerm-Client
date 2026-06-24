# ADR-013: SFTP Channel Gate Enforcement

- Status: Accepted for A2.3e-2
- Date: 2026-06-21
- Scope: Rust Core checked SFTP channel access through verified base sessions

## Context

A2.3d added a checked SSH connection that can publish an Active
`HostKeyVerified` base session into SessionPool. SFTP remains a Critical bypass
until a new SFTP channel can be opened exclusively from that verified base.
The legacy SFTP path can still create or reuse `LegacyUnverified` sessions, and
the previous mixed-ID resolver may interpret one integer as a base, SFTP, or
terminal identifier depending on which map contains it.

This patch establishes the Rust Core boundary before adding another ABI. It
does not migrate callers, alter the legacy SFTP ABI, or change production SSH
Host Key behavior.

## Decision

Add three internal layers:

1. A base-only resolver that accepts only a base-session namespace ID and
   queries only the base-session map.
2. A verified base gate that permits only Active `HostKeyVerified` sessions.
3. A checked SFTP opener that obtains a session channel through that gate,
   requests the `sftp` subsystem, and registers metadata-bound SFTP state.

The API is Rust-only in A2.3e-2. A2.3e-3 may expose it through a thin additive
JSON C ABI after the core invariants are independently tested.

## Base-Only Resolution

Base-session IDs now carry a small in-memory namespace tag in their high bits.
The counter remains below the JSON-safe integer limit. SFTP and terminal IDs
keep their current allocation and legacy behavior.

`resolve_base_session_by_base_id` first validates the base namespace and then
queries only `BASE_SESSIONS`. It never calls the legacy fallback resolver and
never inspects SFTP or terminal maps. Consequently, an SFTP or terminal ID
cannot be guessed or reinterpreted as a checked base ID.

Session IDs are opaque process-local handles, so changing newly allocated base
ID values does not require persistence or data migration. Existing C function
signatures and response formats are unchanged.

## Verified Base Gate

`require_active_verified_base_session` returns a
`VerifiedBaseSessionGuard` only when:

- the base ID resolves in the base namespace;
- metadata state is `Active`;
- security generation is `HostKeyVerified`.

`LegacyUnverified`, Draining, Terminating, and Closed sessions fail closed.
The guard captures the exact security generation and can compare it with an
expected generation when a later caller needs pinning. A checked SFTP ABI only
needs the opaque base ID initially because the base session already owns the
verified generation; callers cannot supply or forge it.

The guard is revalidated before channel creation and again before SFTP
registration. This narrows the state-change window without holding the
SessionPool lock across network operations. A future trust-store watcher may
move sessions to Draining or Terminating; failed revalidation prevents the new
SFTP session from being published.

## Checked SFTP Open

`open_sftp_channel_checked` performs the following sequence:

1. resolve and gate the base session;
2. revalidate the guard;
3. open an SSH session channel through the verified base handle;
4. request the `sftp` subsystem;
5. revalidate the guard;
6. register the SFTP session with checked metadata;
7. return an opaque SFTP session ID.

Channel-open and subsystem-request failures are distinct structured errors.
No checked failure falls back to a legacy connection. The function performs no
credential handling, Known Hosts writes, UI work, or C ABI serialization.

## SFTP Metadata

Every newly registered SFTP session records:

- the originating base-session ID;
- the complete `SessionSecurityGeneration` value;
- creation time;
- whether the registration source was `Checked` or `Legacy`.

Metadata contains no credentials, complete public key, or Known Hosts path.
Its Debug representation redacts the security generation. A later patch can
use this metadata to revalidate list, upload, download, and mutation operations
without changing the SFTP object model again.

Legacy SFTP registration is marked `Legacy` but otherwise retains its previous
behavior. This patch deliberately does not enforce metadata checks on existing
legacy list, upload, download, rename, delete, mkdir, or stat calls.

## Error Codes

`CheckedChannelAccessError` distinguishes:

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
- `internal_invariant`.

Stable protocol error codes are reserved now so A2.3e-3 can remain a thin
adapter. No JSON kind or C ABI is added in this patch. Errors, Debug output, and
future payloads exclude credentials, complete public keys, and local paths.

## Non-Goals

This patch does not:

- add or modify any C ABI or C header;
- modify Swift, Android, or Go;
- change `orbit_sftp_connect` or legacy SFTP behavior;
- change ordinary or checked SSH connection behavior;
- modify the production accept-all Handler;
- migrate Monitor, Docker, batch command, or remote command;
- write Known Hosts, add UI, replace Changed keys, alter RSA policy, or add
  ProxyJump.

Monitor, Docker, and batch command remain release-blocking bypasses and must be
handled in separate patches. Docker command-injection risk is also separate
from this Host Key channel gate.

## Testing

Unit tests use synthetic base sessions and an injected channel backend; default
tests never require an external SSH server. They verify:

- base-only namespace resolution and rejection of SFTP/terminal-like IDs;
- Active verified access and Legacy/Draining/Terminating/Closed rejection;
- exact security-generation mismatch rejection;
- gate-before-channel ordering;
- distinct open, subsystem, and registration failures;
- checked metadata binding and redacted Debug output;
- stable future JSON error codes;
- all legacy SFTP, checked SSH, and ordinary SSH regressions.

## Rollback

Rollback removes the Rust-only checked SFTP module, base-only resolver, checked
metadata path, and additive error-code reservations. It does not alter or
migrate Known Hosts files and does not remove legacy ABI symbols.

Because base IDs are process-local, rollback requires only restarting the
process; no persisted identifier migration exists. This rollback boundary is
for development only. It must not be interpreted as permission to ship legacy
SFTP networking in Release.

## Follow-up

A2.3e-3 should add an additive checked SFTP C ABI that accepts a verified base
session ID and request ID, calls `open_sftp_channel_checked`, and returns a
versioned JSON envelope. It must not accept host credentials or create a new
physical connection. Later patches must enforce equivalent verified-session
gates for SFTP operations, Monitor, Docker, batch command, and remote command
before the Release gate disables all legacy bypasses.
