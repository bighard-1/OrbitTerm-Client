# ADR-002: SSH Host Key Verification Flow

- Status: Accepted for Epic A2.1
- Date: 2026-06-20
- Scope: Pure Rust verification decisions only

## Context

ADR-001 established OrbitTerm's OpenSSH-compatible host identity, Known Hosts parser, matcher, SHA-256 fingerprint formatter, bounded local store, and atomic persistence primitives. Those primitives deliberately remain disconnected from production SSH sessions.

The current `OrbitSshClientHandler::check_server_key()` still accepts every presented server key. That behavior remains unchanged during A2.1 so the decision core can be reviewed and tested independently. It is a release-blocking risk and must be removed only after the challenge protocol, platform UI, persistence flow, and integration tests are complete.

## Decision

Epic A2.1 introduces a pure `HostKeyVerifier` that converts a validated connection target, presented host key, and loaded `KnownHostsStore` into one explicit pre-authentication decision:

- `Trusted` -> `Proceed`
- `Unknown` -> `Challenge`
- `Changed` -> `Block`
- `Revoked` -> `Block`
- `Unsupported` -> `Block`
- invalid identity, algorithm, or public key -> `Fail`
- store or verifier failure -> `Fail`

Only `Proceed` may allow a later connection layer to begin password or public-key authentication. `Challenge`, `Block`, and `Fail` are terminal for the current connection attempt.

## Goals

- Centralize host-key decision semantics in a small, testable Rust module.
- Reuse the A1 `HostIdentity`, `HostKeyState`, `KnownHostsStore`, matcher, and fingerprint implementation.
- Normalize and validate host-key algorithms and public-key material before matching.
- Produce structured values suitable for a future versioned FFI response.
- Reserve security-generation metadata that can later stop a checked request from reusing a legacy unverified pooled session.

## Non-goals

A2.1 does not:

- modify `OrbitSshClientHandler` or `check_server_key()`;
- modify SessionPool behavior;
- connect to a network or authenticate an SSH user;
- read a platform default path or write a Known Hosts file;
- add a pending challenge registry or challenge identifier;
- add accept, reject, or replacement operations;
- change the C FFI or UniFFI surface;
- modify Swift, Android, or Go code;
- add Apple UI;
- change RSA or SSH algorithm policy;
- implement ProxyJump or MITM integration tests.

## Pre-authentication boundary

SSH server identity verification must complete before OrbitTerm sends a password, signs an authentication challenge with a private key, opens a PTY, starts SFTP, executes Docker or monitoring commands, or reuses the connection for another channel.

The verifier itself performs no authentication. A later handler integration may continue only when the verifier returns `Proceed`.

## Decision model

`HostKeyVerificationDecision` has four variants:

- `Proceed(VerifiedHostKey)`: the identity, algorithm, and key match a trusted record.
- `Challenge(HostKeyChallengeDraft)`: the key is unknown and requires explicit user confirmation in a later connection attempt.
- `Block(HostKeyBlock)`: a changed, revoked, or unsupported trust condition prevents authentication.
- `Fail(HostKeyVerificationError)`: verification could not safely complete.

The types intentionally contain no password, private key, private-key passphrase, access token, SSH handle, or platform path.

## Unknown keys

An unknown key never continues to authentication. This includes a host not present in the store and a new algorithm presented by a host that has a trusted key under another algorithm.

A2.1 returns a `HostKeyChallengeDraft` containing display-safe identity data, algorithm, SHA-256 fingerprint, reason code, and capability flags. It does not assign a challenge identifier, retain state, or expose the full public-key blob to UI-facing models.

The full public key remains part of the internal verification input because a later Rust registry must persist the exact key after confirmation. A2.2 will define its bounded lifetime and ownership.

## Changed keys

A changed key is not equivalent to an unknown key. It returns `Block` with the presented fingerprint and, when available, the previous trusted fingerprint. It never enters the ordinary first-use trust path.

A future verified replacement flow must use a distinct action, explicit secondary confirmation, a freshly loaded store, and a new SSH handshake.

## Revoked keys

An exact `@revoked` match has priority over a trusted record and returns `Block`. It never produces an acceptable challenge and cannot be overridden by adding a normal trusted record.

## Unsupported records

Applicable `@cert-authority` and unsupported marker semantics return `Block`. Certificate-authority records are parsed but are not treated as trusted until SSH certificate validation has a separately reviewed implementation and interoperability tests.

## Invalid input and verifier failures

Invalid host identity, host-key algorithm, or public-key material returns a structured failure without echoing the public key. A matcher invariant failure also fails closed.

The existing matcher has no fallible API beyond its explicit state result. `MatcherInvariant` therefore represents an internally inconsistent result, such as a trusted state without a corresponding record summary, rather than a string-parsed matcher error.

## Store failures

`HostKeyVerifier::verify_loaded` accepts the result of loading a store. A load failure maps to `Fail(StoreUnavailable)` and never to an empty store or Accept-All behavior.

Parser warnings remain non-fatal and do not invalidate unrelated valid records. A malformed line never becomes trusted. Store diagnostics can surface warnings in a later management interface.

## Fingerprints and record summaries

UI-facing decisions contain OpenSSH-style SHA-256 fingerprints without Base64 padding. They do not contain full public keys. Trusted decisions retain only the matched record line and marker summary needed for diagnostics and later security-generation tracking.

## SessionPool security generation

A2.1 defines, but does not integrate, `SessionSecurityGeneration`:

- `LegacyUnverified`
- `HostKeyVerified { host_identity, key_algorithm, fingerprint_sha256 }`

A2.3 must include this generation in SessionPool reuse eligibility. A checked request must never reuse a session established by the legacy Accept-All path, and different identities, algorithms, or fingerprints are not equivalent generations.

## Why FFI does not wait for UI

Synchronous C FFI must not hold an SSH socket or block a worker while waiting for a Swift sheet. A2.2 will close the pre-authentication connection, return a bounded challenge to the caller, persist a confirmed key through a separate operation, and require a fresh checked connection.

A2.1 creates only the stateless challenge draft. It does not implement that protocol.

## Follow-up phases

- A2.2a: bounded pending challenge registry, cryptographically random identifiers, expiration, and concurrency rules.
- A2.2b: additive versioned JSON C FFI responses and accept/reject operations.
- A2.3: inject HostIdentity and the verifier into all SSH entry points, enforce verification before authentication, and prevent legacy session reuse.
- A2.4: Apple Application Support path provider, trust coordinator, and Unknown/Changed/Revoked UI.
- A2.5: OpenSSH interoperability, changed-key, revoked-key, concurrent challenge, storage failure, and MITM tests.
- A2.6: remove production Accept-All and enforce a release build gate against its return.

## Test strategy

Unit tests cover every decision state, host/IP and port isolation, IPv6, hashed hosts, algorithm separation, revoked precedence, malformed-line isolation, output safety, store-error fail-closed behavior, and security-generation inequality.

Later integration tests must prove that no authentication message is sent after any result other than `Proceed`.

## Rollback

A2.1 is additive. It can be rolled back by removing the verifier module, its exports and tests, and this ADR. No data migration is required. The production handler, FFI ABI, Swift client, SessionPool, and Known Hosts file format remain unchanged.

Rollback of later phases must never turn a Release build back into Accept-All. Until A2.6 is complete, legacy behavior may exist only behind an explicitly internal build boundary.
