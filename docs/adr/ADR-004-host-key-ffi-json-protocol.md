# ADR-004: Versioned Host Key FFI JSON Protocol

- Status: Accepted for Epic A2.2b-1
- Date: 2026-06-20
- Scope: Pure Rust DTOs, mappings, and JSON validation only

## Context

ADR-001 established the Known Hosts model and store. ADR-002 added pure host-key verification decisions. ADR-003 added a bounded pending challenge registry with secure identifiers, expiry, capacity limits, and deterministic tests.

OrbitTerm's existing C FFI commonly returns `OK:` or `ERR:` prefixed strings. That is adequate for simple scalar results but is too fragile for host-key workflows containing a result kind, request correlation, challenge metadata, changed/revoked state, structured error codes, retry guidance, and localized message keys.

## Decision

OrbitTerm will use a versioned JSON envelope for additive checked-host-key FFI functions. Epic A2.2b-1 defines and tests the protocol in pure Rust but does not add a C ABI, global registry, handler integration, Swift code, or production behavior change.

The wire envelope is:

```json
{
  "schema_version": 1,
  "request_id": "request-123",
  "kind": "host_key_challenge",
  "data": {},
  "error": null
}
```

`schema_version` is exactly `1`. Non-error results contain `data` and a null `error`. Error results contain a null `data` and a structured `error`. Mixed or missing combinations are rejected.

## Why C ABI is deferred

The protocol must be stable and independently testable before it becomes an ABI consumed by Swift. Deferring the C entry points keeps DTO design, serialization behavior, error mapping, memory ownership, Registry synchronization, and handler integration as separately reviewable changes.

No function in A2.2b-1 allocates a C string, accepts a raw pointer, blocks on UI, owns a socket, or changes `check_server_key()`.

## Result kinds

Stable snake-case kinds are:

- `connected`
- `connection_test_succeeded`
- `host_key_challenge`
- `host_key_blocked`
- `host_key_trust_persisted`
- `host_key_rejected`
- `error`

Kinds describe protocol state rather than user-visible prose. Payload shape is selected by kind and validated during deserialization.

## Payloads

### Challenge

The challenge payload includes challenge/request identifiers, host display and normalized identities, port, lookup token, algorithm, SHA-256 fingerprint, unknown-host reason and state, trust capability flags, and Unix expiry seconds.

It never includes the complete public key. The Rust pending Registry retains that key until acceptance.

### Blocked

The blocked payload includes presented and optional previous fingerprints, structured reason/state, capability flags, and a localization message key. Changed, revoked, unsupported marker, and unsupported certificate-authority states remain distinct.

Changed is the only blocked state that may advertise a future separately verified replacement flow. It is not an ordinary trust action.

### Connected and connection test

Connected includes the session identifier and verified host-key security generation. Connection-test success contains the same verified host identity without a session identifier. A `LegacyUnverified` generation cannot be represented as a checked connection.

### Trust persisted

Trust-persisted indicates that an accepted key has subsequently been saved successfully. Registry acceptance by itself is not persistence. The conversion helper is intentionally named `from_accepted_after_persist` to make this ordering requirement explicit; A2.3 must call it only after a successful atomic store save.

### Rejected

Rejected contains a display-safe summary and no public key. Swift will terminate the associated connection attempt.

## Error codes

Stable snake-case codes cover host-key states, Known Hosts read/save/permission/size errors, challenge lifecycle and capacity errors, invalid request/JSON/UTF-8, internal FFI errors, and SSH connection/authentication errors.

Rust errors are mapped by enum matching, never by parsing their display strings. Each payload includes a stable localization key, a bounded diagnostic detail code, retry guidance, and optional request/challenge identifiers.

Error payloads exclude source error text, full paths, public keys, passwords, private keys, passphrases, and tokens.

## Schema compatibility

Version `1` is required. A different version returns a distinct unsupported-schema error rather than being treated as malformed JSON.

Within the same schema version, unknown envelope and payload fields are ignored to support additive forward-compatible fields. Required known fields remain mandatory. Unknown enum values are rejected because they change control-flow semantics and require a newer client.

Changing an existing field's meaning, type, requiredness, enum meaning, or security behavior requires a new schema version.

## Validation

Deserialization validates:

- schema version;
- kind-to-payload correspondence;
- mutual exclusion of `data` and `error`;
- required payload presence;
- matching envelope and payload request IDs;
- canonical challenge ID shape;
- host identity, port, and lookup-token consistency;
- SHA-256 fingerprint shape;
- reason/state/capability consistency;
- checked security generation;
- stable message key and retry policy for each error code;
- bounded diagnostic detail-code syntax.

## Swift Codable compatibility

- All keys use stable snake_case.
- Enums use stable snake-case strings rather than numeric magic values.
- Time uses Unix seconds.
- Port is an integer and capabilities are JSON booleans.
- Optional fields are explicit nullable fields.
- Fingerprints, message keys, reason codes, request IDs, and challenge IDs are strings.
- The top-level layout uses fixed fields rather than dynamic key maps.

Swift A2.4 will decode the envelope by kind and map reason/error/message keys to localized UI. It will not parse `OK:` or `ERR:` to decide host-key security state.

## Sensitive information policy

The JSON protocol never contains:

- passwords;
- private keys or passphrases;
- access or refresh tokens;
- the complete presented host public key;
- local Known Hosts paths;
- raw storage or SSH error strings;
- socket, session, or Swift pointer addresses.

Public SHA-256 fingerprints are included because they are required for user verification. Complete public host keys remain in the bounded Rust Registry and later persistence service.

## Follow-up phases

- A2.2b-2 will add additive, versioned C ABI functions that serialize these envelopes and use a synchronized bounded Registry instance.
- A2.3 will integrate the verifier with every SSH entry point and produce challenge, blocked, connected, and error results before authentication.
- A2.3 persistence will reload and validate the store before writing, then produce trust-persisted only after successful atomic save.
- A2.4 will add Swift Codable models, an Apple trust coordinator, and Unknown/Changed/Revoked UI.
- A2.6 will remove production Accept-All after all release gates pass.

## Test strategy

Tests cover every result kind, all stable error-code strings, payload conversion, request/challenge round trips, unknown fields, missing required fields, unsupported versions, data/error invariants, request mismatches, timestamps, security generation, internal error mapping, path and key exclusion, and JSON round trips.

Future C ABI tests must also cover UTF-8 input, null pointers, returned string ownership, exactly-once free behavior, concurrent Registry access, and malformed JSON requests.

## Rollback

A2.2b-1 is additive. Rollback removes the protocol and error-mapping modules, exports, tests, and this ADR. It introduces no C symbols, persistent format, platform code, network behavior, or migration requirement. Production SSH behavior remains unchanged.
