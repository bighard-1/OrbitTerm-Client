# ADR-006: Transactional Host Key Trust Persistence

- Status: Accepted for A2.2b-3
- Date: 2026-06-20
- Scope: pending Host Key challenge to OrbitTerm-owned `known_hosts`

## Context

ADR-005 introduced additive challenge lifecycle C ABI functions. Its plain
accept operation consumes an in-memory challenge but intentionally does not
persist trust. That operation cannot represent the production user flow
"confirm trust, save the key, then reconnect".

This patch adds `orbit_hostkey_challenge_accept_and_persist_v1`. It still does
not connect the SSH handler, Swift, or any production connection path.

## Decision

Trust persistence uses a three-stage transaction:

1. Lock the bounded registry, validate the challenge and copy a redacted-debug
   pending snapshot, then release the lock.
2. Load and update the caller-supplied OrbitTerm `known_hosts` file using the
   snapshot, then atomically save it without holding the registry lock.
3. Lock the registry again and atomically mark the exact snapshot Persisted by
   comparing challenge ID, HostIdentity, algorithm, fingerprint, public key,
   timestamps, and store generation hint.

The challenge remains pending throughout file I/O. Store read, validation, and
save failures therefore do not consume it.

## Why persistence must precede consumption

Consuming before saving would force users to reconnect after a disk-full,
permission, malformed-file, or path error. More importantly, it could let an
API report acceptance without a durable trust record. Only a successful Store
operation followed by a successful registry CAS produces
`host_key_trust_persisted`.

Plain `orbit_hostkey_challenge_accept_v1` remains
`accepted_not_persisted` and is not the production trust-confirmation API.

## Registry extensions

`snapshot_pending` validates TTL and state but does not consume the entry. Its
snapshot contains the public Host Key for Rust-internal persistence and uses a
custom Debug implementation that redacts it.

`mark_persisted_if_pending` performs a CAS-style binding check. It fails if the
challenge was accepted, rejected, expired, replaced, or no longer matches the
snapshot. A successful commit removes the public key and records a bounded
Persisted tombstone. Subsequent accept, reject, or persist calls return
`challenge_already_resolved`.

## Filesystem I/O and locking

No filesystem operation occurs while holding the registry mutex. The Store
continues to enforce its one-megabyte read limit and atomic temporary-file,
flush, sync, and rename sequence.

This patch does not add cross-process file locking. Concurrent processes that
write the same file could still race at the file level. The Apple platform
layer should use one app-owned path and one process-local service. A later
hardening patch may add file generation checks or advisory locking if multiple
process writers become a supported scenario.

## Path ownership

The caller supplies an absolute UTF-8 path. Rust accepts only paths with an
OrbitTerm-named component, rejects `.`/`..`, and rejects any `.ssh` component.
This keeps the ABI away from the system `~/.ssh/known_hosts` path. Swift will
later provide an Application Support path.

Missing parent directories are created. On Unix, a newly created final parent
directory is set to `0700`; Store output remains `0600`. Existing parent
directory permissions are not silently changed. Invalid paths never fall back
to a temporary location.

The ABI path check is defense in depth, not a sandbox against a malicious
native caller with arbitrary filesystem access.

## Store decision rules

- Unknown: add the exact HostIdentity, algorithm, and public key, then save.
- Trusted with the same key: return idempotent `already_trusted`; no rewrite is
  required.
- Changed: fail closed with `host_key_changed` and keep the challenge pending.
- Revoked: fail closed with `host_key_revoked` and keep the challenge pending.
- Unsupported or `@cert-authority`: fail closed with
  `host_key_unsupported` and keep the challenge pending.
- Invalid key, invalid comment, oversized file, read, permission, or save
  errors: return a structured error and keep the challenge pending.

Changed-key replacement, revoked overrides, and certificate-authority trust are
explicitly outside this patch.

## Comments

A null comment uses `OrbitTerm`. Explicit comments pass through the existing
Store sanitizer: control characters collapse to spaces, blank comments are
omitted, and comments longer than 512 characters are rejected. Comments never
include credentials, usernames, local paths, or tokens by default.

## Success response

Only a completed Store operation plus registry CAS returns:

- kind: `host_key_trust_persisted`
- status: `trusted_added` or `already_trusted`

The JSON payload contains HostIdentity, algorithm, and SHA256 fingerprint but
never the full public key or local path.

## Save-success / CAS-failure boundary

The file may become trusted immediately before a concurrent reject, accept, or
expiry causes the registry CAS to fail. The API must not return ordinary
success in this case. It returns `challenge_mismatch` with detail
`trust_persisted_registry_commit_failed`.

The durable trusted record is intentionally not rolled back: rewriting the
file could overwrite an unrelated concurrent update. A subsequent checked
connection will observe Trusted and recover idempotently. This edge is tested
at the Registry CAS level and must remain visible in diagnostics.

## C ABI and ownership

`orbit_hostkey_challenge_accept_and_persist_v1` is additive. It returns an
ADR-004 JSON envelope allocated by Rust and released by
`orbit_free_string`. Input pointers are borrowed only during the call and are
never retained.

Null pointers, invalid UTF-8, invalid paths, lifecycle errors, Store errors,
and panic boundaries all produce JSON error envelopes. Responses exclude full
public keys, paths, passwords, private keys, passphrases, and authentication
tokens.

## Why Handler and Swift remain unchanged

The SSH handler does not yet register challenges, and Swift does not yet decode
or call this API. Keeping this patch isolated allows persistence semantics to be
tested before it can affect authentication or user workflows.

A2.3 should register Unknown Host challenges before authentication and close
the pre-authentication connection. A2.4 should show the confirmation UI, call
this persistence API, and reconnect only after `host_key_trust_persisted`.

## Tests

Tests cover null and invalid UTF-8 inputs, missing parent creation, Unix
permissions, atomic first trust, reloading as Trusted, idempotent existing
trust, custom ports, IPv6, DNS/IP isolation, comment sanitization, oversized
files, permission failure, Changed, Revoked, unsupported CA records, expiry,
reject, plain accept, snapshot/CAS mismatch, JSON redaction, Header declarations,
and dynamic-library symbol export.

## Rollback

The new C symbol, persistence module, and Registry snapshot/CAS methods are
additive and unused by production callers. They can be removed without changing
legacy ABI or SSH behavior. Existing OpenSSH-format Store files need no data
migration. Rollback must not reinterpret plain accepted challenges as durable
trust.
