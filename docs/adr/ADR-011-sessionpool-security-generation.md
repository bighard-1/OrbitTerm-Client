# ADR-011: SessionPool Security Generation

- Status: Accepted for A2.3c
- Date: 2026-06-21
- Scope: Rust SessionPool identity, lifecycle, and reuse isolation

## Context

A2.3b added a test-only connection that performs real SSH KEX, Host Key
verification, and a pre-authentication trust-store generation recheck. The
ordinary production path remains accept-all. Before adding an ordinary checked
connection, SessionPool must prevent a checked request from reusing a physical
connection created by that legacy path.

The previous pool index was a string built from host, port, and username. It
contained no security state. It also checked the index, performed asynchronous
connection and authentication, and then inserted the result without a keyed
in-flight gate. Concurrent requests could therefore create duplicate physical
connections for the same key. A detected disconnect emitted an event but left
the stale key indexed until explicit release.

## Decision

SessionPool now uses a typed `BaseSessionKey` containing:

- endpoint identity;
- trimmed username;
- complete `SessionSecurityGeneration`.

`SessionSecurityGeneration` is hashable and remains either
`LegacyUnverified` or `HostKeyVerified` with HostIdentity, Host Key algorithm,
SHA-256 fingerprint, and opaque `TrustStoreGeneration`. It contains no complete
public key, Known Hosts path, password, private key, passphrase, or token.

## Legacy Key Strategy

The existing `get_or_create_base_session` signature and callers are unchanged.
It builds `BaseSessionKey::legacy`, preserving the old endpoint formatting and
username trimming, and creates `BaseSessionMetadata::new_legacy`. The session
is `Active + LegacyUnverified`.

Because the generation is part of equality and hashing, legacy lookup cannot
find a verified entry. It also cannot replace a verified key in the typed
index. No legacy network or authentication behavior changes in this patch.

## Checked Key Strategy

`BaseSessionKey::checked` requires a valid `HostKeyVerified` generation and
derives its endpoint from normalized `HostIdentity`. It rejects
`LegacyUnverified`, malformed HostIdentity, malformed algorithm/fingerprint,
and invalid username input.

`lookup_base_session_checked` is an internal, production-unwired lookup API. It
requires an exact checked key, applies the metadata channel gate, and acquires
a session reference atomically. It never creates an accept-all connection.

This patch deliberately does not insert checked physical sessions. russh
encodes the handler type in `client::Handle`, so storing both legacy and checked
handles requires the focused A2.3d connection-storage design. Pretending to
create a checked session with the legacy handler would defeat this ADR.

## Session Metadata

Each base session carries `BaseSessionMetadata`:

- security generation;
- creation time;
- atomic lifecycle state.

States are `Active`, `Draining`, `Terminating`, and `Closed`. Transitions are
monotonic:

- Active may move to Draining, Terminating, or Closed;
- Draining may move to Terminating or Closed;
- Terminating may move to Closed;
- Closed cannot return to an active state.

Idempotent transitions are allowed. Invalid backwards transitions return a
structured error.

## Channel Gate

`BaseSessionMetadata::assert_allows_new_channel` first requires `Active`, then
requires exact generation equality. A verified request against a legacy
session returns `LegacySessionNotAllowed`. A different algorithm, fingerprint,
HostIdentity, or Store generation returns `SecurityGenerationMismatch`.

Draining, Terminating, and Closed each return a distinct structured error. The
gate performs no network operation and can be reused by terminal, SFTP,
Monitor, Docker, and command paths in later migration patches.

Those production call sites are intentionally not switched in A2.3c. Existing
sessions are all Active legacy sessions, and changing channel behavior here
would exceed the stated scope. A2.3d and the later SFTP/Monitor/Docker coverage
patch must call the gate before every new channel.

## Trust Change Policy

The lifecycle model reserves these policies:

- deleting a trusted record marks matching verified sessions Draining, allowing
  existing channels to finish but denying new channels;
- Changed or Revoked marks matching sessions Terminating, denying new channels
  before a later task actively disconnects the transport;
- Closed entries are removed from the reuse index.

There is no Known Hosts watcher in this patch, so these transitions are exposed
and tested but not triggered automatically.

## Concurrent Creation Gate

Session creation now uses a per-`BaseSessionKey` Tokio mutex. The global gate
map stores only weak references. The global mutex is held only while selecting
a gate and never during DNS, TCP, KEX, or authentication.

The creator rechecks the pool after acquiring the key gate. Equivalent
concurrent legacy requests therefore share the newly created session. Different
security generations use different gates. Failed creation drops the strong
reference, allowing the next request to retry; dead weak entries are pruned on
the next gate lookup.

This avoids a shared-future dependency, global async lock, or permanent failed
in-flight entry.

## Reference and Disconnect Safety

Session references now use atomic compare/update operations. A reference cannot
be acquired after the count reaches zero, and duplicate release cannot
underflow the counter. Index removal checks both key and session ID so an old
session cannot remove a newer replacement.

The keepalive watcher marks a closed transport `Closed` and removes its reuse
index entry before emitting the connection-lost event. The base object remains
available to existing holders until their references are released.

## Errors

`SessionSecurityError` distinguishes legacy rejection, verified requirement,
generation mismatch, invalid checked generation/identity, Draining,
Terminating, Closed, invalid state transition, and internal invariant failure.
Errors contain no credentials, complete public keys, or local paths and can be
mapped to versioned JSON in A2.3d without parsing text.

## Non-Goals

This patch does not:

- change `OrbitSshClientHandler::check_server_key`;
- add or modify C ABI, C headers, Swift, Android, or Go;
- create ordinary checked connections;
- migrate SFTP, Monitor, Docker, terminal, or command channel call sites;
- watch or write Known Hosts;
- terminate transports on trust changes;
- add Feature Flags, RSA policy, ProxyJump, MITM tests, or terminal styling.

## Testing

Pure Rust tests cover all generation components, checked-generation validation,
legacy/checked key isolation, checked hostname normalization, exact index reuse,
fingerprint and Store-generation separation, checked lookup rejection of
legacy input, lifecycle transitions, channel-gate outcomes, per-key creation
gate sharing and cleanup, and redacted debug/error output. Tests do not require
an SSH server or create a network session.

The existing checked test connection, legacy C ABI, and all previous security
tests remain regression gates.

## Rollback

The typed key can be converted back to the prior string index while preserving
base session IDs. Metadata and creation gates are in-memory only. Removing them
does not alter persisted Known Hosts, cloud data, C ABI, or client files. No
rollback deletes user trust records.

## Follow-up

A2.3d should design a safe storage abstraction for checked russh handles, add
the ordinary additive checked connect ABI, attach the coordinator-approved
`SessionSecurityGeneration`, and call the channel gate. SFTP, Monitor, Docker,
terminal, and command paths must then be migrated explicitly before release
can prohibit accept-all.
