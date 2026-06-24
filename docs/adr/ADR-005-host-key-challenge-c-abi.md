# ADR-005: Host Key Challenge C ABI

- Status: Accepted for A2.2b-2
- Date: 2026-06-20
- Scope: additive C ABI around the in-memory Host Key challenge registry

## Context

ADR-004 defines the versioned Host Key JSON protocol. Apple clients will
eventually need a stable C ABI to inspect and resolve pending Host Key
challenges without parsing the legacy `OK:` / `ERR:` protocol.

The production SSH handler still accepts server keys through the legacy path.
This ADR does not connect the new ABI to the handler or change connection
behavior.

## Decision

Add versioned, additive C symbols:

- `orbit_hostkey_challenge_accept_v1`
- `orbit_hostkey_challenge_reject_v1`
- `orbit_hostkey_challenge_status_v1`
- `orbit_hostkey_challenge_cleanup_expired_v1`
- `orbit_hostkey_protocol_version_v1`

Every function returns an ADR-004 JSON envelope. Existing symbols and their
legacy return formats remain unchanged.

## Registry ownership

The C ABI owns one process-local `OnceLock<Mutex<PendingHostKeyChallengeRegistry>>`.
The registry retains the A2.2a TTL and capacity limits. It is not a naked
mutable static. Lock scope contains only bounded in-memory registry operations;
there is no UI, network, SSH, or filesystem work while holding the lock.

A poisoned lock fails closed with `ffi_internal_error`. Tests can replace the
registry through a crate-private `#[cfg(test)]` helper so each scenario begins
from known state.

The later Handler integration must register challenges in this same container.
It must not create a second registry namespace.

## Accept is not persistence

`orbit_hostkey_challenge_accept_v1` atomically consumes a pending challenge but
does not write `known_hosts`, reconnect, or authenticate. Its response kind is
`host_key_challenge_accepted` and its status is
`accepted_not_persisted`. It must never return `host_key_trust_persisted`.

This function is an ABI/lifecycle primitive and is not the future production
Swift trust workflow. A later patch must add an atomic `accept_and_persist`
operation that consumes the challenge and writes the trusted record as one
coordinated operation. If persistence fails, that operation must preserve or
restore a resolvable challenge rather than claim success.

## Reject, status, and cleanup

- Reject consumes a pending challenge, drops its public key, and records a
  bounded rejection tombstone.
- Status returns `pending`, `accepted`, `rejected`, `expired`, or
  `invalidated_by_store_change` while the bounded tombstone exists.
- Cleanup removes expired pending entries and returns only the number expired.
  It does not expose map contents, host identities, keys, or capacity details.

## Public key lifecycle

The full public key remains inside the bounded Rust registry. Accept returns it
only to the Rust ABI implementation, which immediately drops it after creating
the redacted accepted response. Reject and expiry remove it without returning
it. No JSON response contains the full public key.

No password, private key, passphrase, authentication token, SSH session,
socket, Swift pointer, or filesystem path is stored in the registry.

## C string ownership

Return values are NUL-terminated strings allocated by Rust with
`CString::into_raw`. Callers must release every non-null result with the
existing `orbit_free_string` function. Inputs are borrowed only for the
duration of the call and copied before use; input pointers are never retained.

The caller must provide a valid readable NUL-terminated pointer. Null pointers
and invalid UTF-8 produce JSON errors. Allocation failure is process-fatal under
Rust's default allocator behavior; if an otherwise valid response cannot be
encoded as a C string, the implementation attempts a constant JSON error and
may return null only if even that allocation cannot be produced.

## Panic and error boundary

Each new ABI entry catches Rust unwinding and converts it to
`ffi_internal_error`. No panic is intentionally allowed across the C boundary.

Important mappings include:

| Condition | Error code |
| --- | --- |
| null challenge pointer | `invalid_request` |
| invalid UTF-8 | `invalid_utf8` |
| malformed challenge ID | `invalid_request` |
| unknown valid ID | `challenge_not_found` |
| expired challenge | `challenge_expired` |
| accepted/rejected tombstone | `challenge_already_resolved` |
| registry lock poison | `ffi_internal_error` |
| serialization failure | `ffi_internal_error` |

Errors contain stable code and message keys, not localized prose, source error
strings, full public keys, credentials, tokens, or local paths.

## Why JSON replaces neither old ABI nor old results yet

Complex Host Key states are unsafe to encode with ad-hoc `OK:` / `ERR:` text,
but existing clients still depend on those legacy symbols. The new ABI is
strictly additive. Swift is not changed in this patch, and the new functions
are not yet part of the production connection flow.

## Future integration

- A2.2b-3 should design and implement atomic accept-and-persist against an
  injected `KnownHostsStore` path supplied by the platform layer.
- A2.3 should register Unknown Host challenges from the SSH handler before
  authentication and terminate the pre-authentication connection.
- A2.4 should decode envelopes in Swift, display Host Key UI, and invoke only
  the persistence-capable trust flow for production confirmation.

## Tests

Rust tests cover protocol version discovery, null and invalid UTF-8 input,
invalid and unknown IDs, accept/reject/status/expiry/cleanup behavior, duplicate
resolution, C string release, sensitive-data exclusion, and header declarations.
The registry is reset under a serial test guard to avoid cross-test pollution.

## Rollback

The new symbols and module can be removed without changing legacy ABI or SSH
behavior because no production caller exists yet. The JSON kinds are additive
within schema version 1 and remain reserved once released. Rollback must not
reinterpret `host_key_challenge_accepted` as persisted trust.
