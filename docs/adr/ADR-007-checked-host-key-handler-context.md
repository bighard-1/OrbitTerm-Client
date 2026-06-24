# ADR-007: Checked Host Key Handler Context

- Status: Accepted for A2.3a
- Date: 2026-06-21
- Scope: Pure Rust security skeleton only

## Context

A1 and A2.1-A2.2b provide OpenSSH-compatible Known Hosts parsing and storage, a
pure verification state machine, a bounded pending challenge registry,
versioned JSON DTOs, additive challenge C ABI functions, and transactional
accept-and-persist support. The production `OrbitSshClientHandler` still
accepts every server key. A2.3a prepares a checked path without changing that
production behavior.

## Decision

OrbitTerm introduces a separate `CheckedHostKeyHandler`. It cannot be default
constructed and requires a `HostKeyVerificationContext`. We do not add a
defaultable Legacy/Checked mode to the production handler because an omitted
or incorrectly initialized mode could silently restore accept-all behavior.

This patch compiles the real `russh::client::Handler` implementation but does
not pass it to `russh::client::connect` anywhere. There is no network, user
authentication, C ABI, UI, SessionPool, or production connection change.

## HostKeyVerificationContext

The context contains only the normalized `HostIdentity`, optional bounded
request ID, an already-loaded `KnownHostsStore`, its `TrustStoreGeneration`, a
`HostKeyVerifier`, an injectable `HostKeyChallengeService`, and a per-attempt
`VerifiedHostKeySlot`. It contains no credentials, private keys, passphrases,
tokens, platform pointers, session handles, sockets, or local file path.

Store loading belongs to the future checked-connect coordinator. A store read
failure prevents context construction and therefore fails closed before KEX.

## TrustStoreGeneration

`TrustStoreGeneration` is an opaque SHA-256 digest of canonical store text. It
contains no path and does not expose source key material through `Debug`. Equal
contents produce equal generations. It is intended for:

- detecting store changes between pre-KEX loading and pre-authentication;
- binding future verified SessionPool entries to a trust generation;
- binding pending challenges to the trust snapshot that produced them.

A2.3b/A2.3c will reload the store before authentication and compare this
generation. This patch does not perform that I/O.

## HostKeyChallengeService

The pending registry is wrapped by a cloneable, injectable service. Its mutex
is private and every method holds the lock only for a bounded in-memory
registry operation. Existing FFI accept, reject, status, cleanup, snapshot, and
persist-CAS operations use the same shared service. File I/O remains outside
the service and outside the registry lock.

The shared FFI instance uses `OnceLock`, while tests and future coordinators can
inject independent service instances. No raw mutex guard is exposed.

## RusshHostKeyAdapter

`russh 0.60.3` passes
`russh::keys::ssh_key::PublicKey` to `check_server_key`. The adapter uses its
`algorithm()` and `to_bytes()` APIs. `to_bytes()` yields the SSH wire-format
public-key blob; the adapter encodes that blob as standard Base64 and formats
its SHA-256 fingerprint. The full public key is retained only in the internal
presented-key value needed to register an unknown challenge. `Debug` redacts
it.

The adapter performs representation conversion only. It does not decide
trust, access Known Hosts, register challenges, write files, or emit JSON.

## ConnectPreAuthError

Pre-authentication outcomes remain structurally distinct:

- `HostKeyChallenge(RegisteredHostKeyChallenge)`
- `HostKeyBlocked(HostKeyBlock)`
- `HostKeyVerificationFailed`
- `ChallengeServiceFailed`
- `AdapterFailed`
- `VerifiedSlotFailed`
- `Protocol`

Store-loading failures occur before handler construction. Store-generation
changes and coordinator invariant failures will be represented by the checked
connect coordinator in A2.3b rather than being prematurely added as unused
handler variants.

These errors do not contain credentials, complete public keys, or Known Hosts
paths. A later C ABI layer will map them to existing versioned JSON DTOs. The
handler itself never creates JSON or localized UI text.

## VerifiedHostKeySlot

The russh connection API returns a handle rather than the consumed handler.
The per-attempt slot provides a narrow handoff of the verified result. Trusted
keys populate it. Unknown, changed, revoked, unsupported, and failed keys do
not. A2.3b-pre2 calls the slot immediately before authentication; an empty,
poisoned, mismatched, or malformed slot fails closed.

The slot now keeps a private, redacted public-key carrier so the coordinator
can re-run the existing verifier if the trust store changes between KEX and
authentication. The public key is excluded from `Debug`, errors, JSON, and
`SessionSecurityGeneration`; the slot validates its embedded SSH algorithm,
declared algorithm, and fingerprint before use. Conflicting second results are
rejected.

## Decision Mapping

| Verifier result | Handler result | Authentication allowed |
| --- | --- | --- |
| Trusted | store verified result, `Ok(true)` | Later coordinator may proceed |
| Unknown | register pending challenge, structured error | No |
| Changed | structured blocked error | No |
| Revoked | structured blocked error | No |
| Unsupported | structured blocked/error result | No |
| Invalid | structured verification/adapter error | No |
| Store unavailable | context construction fails | No |

The handler does not wait for UI, does not keep a half-open connection, and
does not write Known Hosts. A future checked connection will return the
challenge, close the pre-authentication attempt, and reconnect after explicit
trust persistence.

## Challenge Deduplication

A2.3b-pre1 now provides a bounded related-request model for the equivalence
key:

`HostIdentity + key algorithm + SHA-256 fingerprint + TrustStoreGeneration`.

It caps distinct request IDs, returns one challenge ID for equivalent pending
attempts, preserves each registration call's current request ID in its returned
summary, and clears the equivalence index after acceptance, persistence,
rejection, or expiry. Full related-request lists remain internal. See ADR-008.

## Future Integration

- A2.3b-pre2 adds the pure pre-authentication store-generation recheck. The
  next A2.3b patch will attach it to an additive checked test-connection path
  and map structured outcomes to the existing JSON protocol.
- A2.3c will attach `SessionSecurityGeneration` and trust generation to the
  SessionPool before checked reusable sessions are exposed.
- A2.3d will add ordinary checked connect C ABI functions only after pool
  isolation is enforced.
- Later patches will migrate SFTP, Monitor, Docker, and batch-command paths and
  then prohibit accept-all in release builds.

## Testing

Tests cover deterministic store generations, context failure on store errors,
real russh public-key adaptation, trusted slot handoff, unknown challenge
registration, changed/revoked/certificate-authority blocking, service error
mapping, redacted debug output, and continued separation from the production
handler. Existing FFI lifecycle tests remain the regression gate for the
service extraction.

## Rollback

All new handler components are unreferenced by production connection entries.
They can be removed together with this ADR and the service wrapper can be
folded back into the FFI module without changing the Known Hosts file format or
stored trust records. No rollback requires deleting user trust data.
