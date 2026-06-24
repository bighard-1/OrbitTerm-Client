# ADR-003: Pending SSH Host Key Challenge Registry

- Status: Accepted for Epic A2.2a
- Date: 2026-06-20
- Scope: Pure Rust pending challenge lifecycle only

## Context

ADR-001 established the Known Hosts trust model and local store. ADR-002 added the pure Rust `HostKeyVerifier` and its `Proceed`, `Challenge`, `Block`, and `Fail` decisions. Production SSH connections still use the legacy Accept-All handler and remain unchanged during A2.2a.

An unknown server key cannot continue to authentication, but a graphical client also cannot synchronously wait inside a C FFI call while a user reviews a sheet. OrbitTerm therefore needs a bounded, process-local registry that can retain the exact public host key between the initial verification result and a later explicit user decision.

## Decision

Epic A2.2a introduces an injectable `PendingHostKeyChallengeRegistry`. It accepts only an A2.1 unknown-host `HostKeyChallengeDraft`, validates the corresponding complete public-key blob, assigns a cryptographically random identifier, and retains the bounded entry until it is accepted, rejected, or expires.

The Registry performs no networking, authentication, file I/O, Known Hosts save, FFI, UI, or background work. It is an ordinary Rust value rather than a mutable global singleton.

## Why FFI must not wait for UI

A future checked connection will close its pre-authentication socket after an unknown key is observed and return a challenge response immediately. Swift can then display UI without retaining a half-open socket, Tokio task, channel, password, or private key. Confirmation will be a separate operation followed by a fresh SSH handshake.

The Registry is the short-lived bridge between those operations. A2.2a does not expose that bridge through FFI yet.

## Rust-owned public key

The complete public key remains inside Rust until acceptance. Swift will eventually receive only the challenge identifier and display-safe summary. This prevents UI state, diagnostics, and unrelated application layers from carrying the key material needed for the trust-store write.

The public host key is not secret and does not require zeroization, but its lifecycle is still bounded:

- registration stores one canonical Base64 public-key blob;
- display summaries and errors do not include the blob;
- `Debug` output redacts it;
- acceptance removes it from the Registry and returns it to the future persistence caller;
- rejection, expiry, cleanup, or Registry drop releases it;
- no password, private key, passphrase, token, session, socket, or Swift pointer is stored.

## Challenge identifiers

Challenge IDs use 16 bytes of entropy from `rand::rngs::OsRng`, encoded as 22-character Base64URL without padding. They are not counters, timestamps, host-derived hashes, or fingerprint-derived values and therefore disclose no host identity.

Generation retries a bounded eight times if an identifier collides with an active entry or retained tombstone. Entropy-source failure and repeated collisions are structured errors. Tests inject a deterministic `ChallengeIdGenerator` rather than relying on random output.

## Time and expiry

The default challenge TTL is 120 seconds. Registry operations receive `SystemTime` from the caller, making tests deterministic and avoiding a background timer, thread, sleep, or non-cancellable task.

An entry expires when `now >= expires_at`. Expired entries cannot be accepted or rejected. Operations lazily clean expired entries before applying capacity limits. Explicit cleanup is also available.

## Capacity limits

Defaults are:

- 64 active pending challenges globally;
- 4 active challenges per exact `HostIdentity`;
- 64 KiB maximum canonical Base64 public-key input;
- 128 resolved tombstones;
- 120 seconds tombstone retention.

All limits are configurable within reviewed hard bounds. Per-host counting uses the complete normalized identity, including host type and port, so DNS names, IP addresses, port 22, and non-default ports remain separate. Expired entries are removed before capacity checks.

## Lifecycle

Active entries are always `Pending`.

- `accept`: validates the ID, cleans expiry, atomically removes the pending entry, records an `Accepted` tombstone, and returns the host identity, algorithm, fingerprint, complete public key, correlation values, and timestamps.
- `reject`: validates the ID, atomically removes the pending entry and its public key, records a `Rejected` tombstone, and returns only a display-safe rejection summary.
- `expire`: removes the pending entry and public key and records an `Expired` tombstone.
- `cleanup`: removes expired pending entries and old tombstones.

Resolved tombstones contain no public key. They provide stable short-term semantics: duplicate accept or reject returns `ChallengeAlreadyResolved`, while expired challenges return `ChallengeExpired`. After the bounded tombstone TTL they become `ChallengeNotFound`.

`InvalidatedByStoreChange` and `StoreGenerationMismatch` are reserved for A2.2b/A2.3. A future accept operation must reload the Known Hosts store and ensure that a concurrent update has not changed or revoked the presented identity before saving.

## Binding and validation

Each pending entry binds:

- challenge ID;
- optional caller request ID;
- exact `HostIdentity`;
- normalized key algorithm;
- SHA-256 fingerprint;
- complete canonical public key;
- unknown-host reason;
- creation and expiry times;
- optional store-generation hint.

Registration reconstructs and validates the draft identity, requires the A2.1 `UnknownHostKey` semantics, canonicalizes the algorithm and public key with the A1 rules, recomputes the fingerprint, and rejects mismatches. An ID for host A can therefore return only host A's bound entry and cannot be applied to host B.

Changed, revoked, unsupported, and replacement flows cannot be registered through the ordinary unknown-host API. They remain blocked or require a separately designed review operation.

## Concurrency model

The Registry uses ordinary `&mut self` operations and contains no internal lock. This gives register, accept, reject, and cleanup atomic semantics for a single owner and keeps the type easy to test and replace.

A2.2b may hold it in `Arc<Mutex<_>>` at the FFI boundary. The lock must cover lookup, state check, removal, and tombstone insertion as one operation. No Registry method awaits or calls external code while locked, preventing lock inversion and UI deadlocks.

## Structured errors

Errors distinguish invalid IDs, generation failures, collision exhaustion, missing/expired/resolved challenges, global and per-host capacity, public-key size and validity, algorithm and identity validity, invalid draft semantics, configuration errors, correlation value validation, future store-generation mismatch, and internal invariants.

Errors contain no complete public key, credential, host path, or UI-localized prose. A2.2b will map variants to versioned FFI error codes.

## Follow-up phases

- A2.2b: versioned JSON C FFI models and process-owned synchronized Registry instance.
- A2.3: checked handler integration, pre-authentication connection closure, store generation revalidation, and trusted-key persistence after acceptance.
- A2.4: Apple Application Support path, challenge coordinator, and Unknown/Changed/Revoked UI.
- A2.5: OpenSSH, storage-failure, concurrency, expiry, and MITM integration tests.
- A2.6: release-gated removal of production Accept-All behavior.

## Test strategy

Unit tests cover secure ID shape, deterministic ID injection, entropy failure, collision retry and exhaustion, registration binding, global/per-host limits, identity and port isolation, expiry without sleep, cleanup, public-key and draft validation, atomic accept, reject, duplicate resolution, unknown IDs, tombstone retention, output redaction, and invalid configuration.

Later FFI tests must exercise concurrent calls through the synchronization wrapper and verify that no lock is held while returning to Swift.

## Rollback

A2.2a is additive. Rollback removes the Registry module, its exports and tests, and this ADR. No persistent file or FFI schema has been created, and production handler, SessionPool, C ABI, Swift, Android, Go, and SSH behavior remain unchanged.
