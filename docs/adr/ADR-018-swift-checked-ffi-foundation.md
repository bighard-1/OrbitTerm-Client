# ADR-018: Swift Checked FFI Foundation

## Status

Accepted for A2.4a.

## Context

Rust Core already exports additive checked SSH, SFTP, Monitor, Docker, and Host Key trust C ABIs. The Apple bridge header had become an independent handwritten copy and did not expose those declarations. Swift also lacked a schema-aware JSON model and used untyped `UInt64` values for base, SFTP, and terminal identifiers.

This patch intentionally does not call an ABI, open a connection, change `SessionManager`, or add Host Key UI. It establishes the protocol boundary needed by those later patches.

## Decision

### Canonical header

`orbit-core/include/orbit_core.h` is the only canonical C header. `OrbitTerm/CBridge/orbit_core.h` is a forwarding header that includes it by relative path. The existing bridging header continues to import `orbit_core.h`, so legacy and checked declarations are visible without maintaining a second declaration list.

A C11 source in the XCTest target includes the forwarding header and compile-time checks representative legacy, checked, and trust declarations. A separate source-tree check confirms that the forwarding file has no independent `char *orbit_...` declarations. CI should keep both checks.

### DTOs before orchestration

Checked DTOs live in `OrbitTerm/Core/CheckedFFI`, separate from `RustFFI.swift`. They contain no credentials, C pointers, network behavior, UI state, or service coordination. This lets later coordinators consume a tested protocol layer instead of embedding JSON branching in business services.

### Schema and envelope invariants

Swift supports schema version 1 only. Any other schema fails closed. An envelope must be exactly one of:

- success: non-null `data`, null `error`, and a non-error kind;
- failure: null `data`, non-null `error`, and kind `error`.

Both-present and both-missing shapes are rejected. Unknown additive JSON fields are ignored.

### Request identity

`HostKeyRequestID` is a validated, bounded, ASCII request string. New flows use lowercase UUID strings. Envelope, nested error, and nested challenge request IDs are compared where present. Coordinators must generate a new ID per operation and ignore stale responses rather than sharing IDs across flows.

### Session identifiers

`BaseSessionID`, `SFTPSessionID`, and `TerminalChannelID` are distinct String-backed structs, not type aliases. Their canonical representation is a non-zero decimal `UInt64` string. They cannot be implicitly interchanged.

Schema v1 `connected.session_id` is currently a JSON number, while newer checked payloads serialize IDs as decimal strings. `BaseSessionID` therefore supports both forms only through `CheckedFFIWireDecoder`. That decoder inspects the original JSON token and rejects decimal points, exponent notation, signs, whitespace inside strings, zero, and overflow. This avoids Foundation's default behavior of accepting integral-looking `1.0` or `1e3` as `UInt64`. No identifier is decoded through `Double`.

Future Rust schemas should serialize every identifier as a decimal string. Once schema v1 numeric compatibility is retired, the numeric exception can be removed.

### Unknown kinds and codes

Unknown result kinds and error codes preserve their raw strings for diagnostics and forward compatibility. Generic envelope decoding can retain them, but operation-specific dispatch such as checked connect fails closed on an unsupported kind. Swift branches on stable kind and code values, never on localized or natural-language messages.

### Sensitive data

DTOs do not declare password, private-key, passphrase, token, public-key blob, or known-hosts-path fields. Additive unknown fields are ignored and are not retained. Error and payload debug descriptions are minimal or redacted. Callers must not log complete JSON envelopes because logs and remote command output may contain user data even when the schema contains no credentials.

## Testing

`OrbitTermCheckedFFITests` is a standalone macOS XCTest bundle with no App, Rust library, credential, or network dependency. It compiles the five Checked FFI source files directly and covers:

- forwarding-header C11 compilation and representative ABI visibility;
- typed ID canonicalization, large `UInt64`, and lexical rejection;
- schema, request, kind, and data/error invariants;
- connected, Host Key, SFTP, Monitor, and Docker fixtures;
- unknown kind/code handling and redacted descriptions;
- checked-connect kind dispatch and stale-response rejection.

Fixtures use synthetic hosts, fingerprints, container IDs, and logs only.

## Consequences

Apple code can now compile against all canonical checked declarations and can decode their current schema without changing production behavior. Existing legacy APIs remain visible and callable until later migration and release-gate patches.

The numeric `connected.session_id` compatibility path remains schema-v1 technical debt. All new ID fields should remain strings.

## Follow-up

1. A2.4b adds `HostKeyTrustCoordinator` and Unknown/Changed/Revoked UI using these models.
2. A checked PTY additive ABI is required before migrating terminal channel creation.
3. SessionManager and SFTP/Monitor/Docker services then migrate to verified base-session IDs.
4. Release gates finally make legacy networking fail closed.

## Rollback

The DTO and test target can be removed without affecting runtime behavior because no service calls them yet. The forwarding header should not be rolled back to a handwritten copy; if an Xcode path issue appears, use a generated-header or build-time equality check while retaining the Rust header as the single source of truth.
