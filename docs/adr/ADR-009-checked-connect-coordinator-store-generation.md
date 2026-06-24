# ADR-009: Checked Connect Coordinator Store Generation Gate

- Status: Accepted for A2.3b-pre2
- Date: 2026-06-21
- Scope: Pure Rust pre-authentication coordination only

## Context

A2.3a introduced the production-unwired checked Host Key handler and its
verification context. A2.3b-pre1 added bounded equivalent-challenge reuse. A
Host Key trusted during KEX can nevertheless become untrusted before OrbitTerm
sends a password or private-key authentication request:

1. T0 loads Known Hosts and records its generation.
2. T1 KEX verifies the server key and fills the per-connection verified slot.
3. T2 another window deletes, replaces, or revokes the key.
4. T3 the connection reaches the authentication boundary.

Allowing authentication at T3 without observing T2 creates a time-of-check to
time-of-use trust gap. The production SSH path remains accept-all in this
patch; the new coordinator is intentionally not wired to a network entry.

## Decision

Add a pure Rust `CheckedConnectCoordinator`. It owns the per-attempt
`HostKeyVerificationContext` and an injected `KnownHostsStoreReloader`. It
loads the initial store before context construction, hands a clone of the
context to the checked handler, and exposes one pre-authentication decision
gate.

Only `CheckedPreAuthDecision::AllowAuthentication` authorizes a later caller
to send credentials. `Block` and `Fail` are terminal for that connection
attempt.

## Store Reload Abstraction

`KnownHostsStoreReloader` returns a `KnownHostsStore`; the coordinator computes
the opaque `TrustStoreGeneration` itself. Tests inject an in-memory reloader,
so no filesystem path or sleep is required. A later platform-aware checked
entry can wrap the existing `KnownHostsStore::load` API without duplicating
parser or size-limit logic.

Initial load failure prevents context construction. Pre-authentication reload
failure fails closed. Store errors retain structured error kinds but no local
path is stored or emitted by the coordinator.

## Verified Host Key Recheck Material

The public `VerifiedHostKey` summary intentionally remains free of complete
public-key material. Rechecking through the existing matcher requires the
original SSH public-key blob, so the per-connection slot stores an internal
`VerifiedHostKeyForRecheck` carrier containing the summary plus canonical
Base64 public key.

This carrier is private to the Rust security layer. Its `Debug` output redacts
the public key. The material never enters JSON, errors,
`SessionSecurityGeneration`, or UI models. Before use, the slot verifies that:

- the blob parses as an SSH public key;
- the blob's embedded algorithm equals the declared algorithm;
- the SHA-256 fingerprint equals the verified summary.

This avoids duplicating Known Hosts matching with fingerprint-only logic and
prevents an algorithm or fingerprint binding mismatch.

## Generation Decision

The coordinator first requires a populated, internally consistent slot bound
to the same normalized `HostIdentity` as the connection context.

If the current generation equals the initial generation, the already verified
key is approved. No trust-store content changed in the observed interval.

If the generation differs, the coordinator re-runs `HostKeyVerifier` against
the current store using the exact HostIdentity, algorithm, and public key from
the KEX result:

| Current verification | Pre-authentication decision |
| --- | --- |
| Trusted | Allow authentication with the current generation |
| Unknown | Fail closed with `StoreGenerationChangedUnknown` |
| Changed | Block |
| Revoked | Block |
| Unsupported / certificate authority | Block |
| Invalid / verifier error | Fail closed |
| Store reload error | Fail closed |

Unknown does not register another challenge at this late boundary. The caller
must terminate the attempt and begin a fresh checked connection so the new
trust snapshot controls KEX and challenge registration from the start.

## Empty and Mismatched Slots

An empty or unavailable slot fails closed. A slot whose HostIdentity differs
from the context, or whose algorithm/fingerprint does not bind to its public
key, also fails closed. No fallback to accept-all exists in this coordinator.

## Session Security Generation

`SessionSecurityGeneration::HostKeyVerified` now includes the approved
`TrustStoreGeneration` in addition to HostIdentity, algorithm, and fingerprint.
The full public key and store path are excluded. A later SessionPool patch will
use this value to prevent checked requests from reusing legacy or differently
verified physical sessions. This ADR does not modify SessionPool behavior.

## Non-Goals

This patch does not:

- perform TCP, SSH, KEX, or authentication;
- replace the production handler or its current `Ok(true)` behavior;
- add or modify C ABI, C headers, Swift, Android, or Go code;
- write Known Hosts, create challenges, wait for UI, or retain sockets;
- add Feature Flags, MITM integration tests, ProxyJump, or algorithm policy.

## Next Integration

A2.3b checked test connection will create the coordinator, pass its context to
`CheckedHostKeyHandler`, let `russh::client::connect` complete KEX, invoke this
gate immediately before authentication, and map the structured outcome to the
existing versioned Host Key JSON protocol. No synchronous FFI call will wait
for UI.

A2.3c will attach the approved `SessionSecurityGeneration` to SessionPool
entries. Ordinary checked connect and SFTP, Monitor, and Docker migration must
wait until that reuse boundary is enforced.

## Testing

Unit tests use a deterministic fake reloader and real russh public-key blobs.
They cover initial load failure, empty and mismatched slots, unchanged stores,
changed-but-still-trusted stores, changed-to-unknown, changed, revoked,
certificate-authority and unsupported records, reload permission and size
errors, session-generation derivation, and redacted debug output. No test opens
a socket or sends credentials.

## Rollback

The coordinator and recheck carrier are not referenced by production
connection entries. They can be removed without changing the existing C ABI,
Known Hosts file format, persisted trust records, SessionPool, or current SSH
behavior. The `TrustStoreGeneration` field added to the internal session
security type is also production-unwired and can be reverted with its tests.
