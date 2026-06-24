# ADR-008: Equivalent Host Key Challenge Deduplication

- Status: Accepted
- Date: 2026-06-21
- Scope: Pure Rust pending challenge lifecycle

## Context

A2.3a introduced the checked Host Key handler skeleton. Concurrent attempts to
the same unknown Host Key could previously create separate pending entries and
eventually produce duplicate confirmation UI. The original registry retained
one request ID per challenge and had no safe equivalence index.

This patch remains disconnected from production SSH, C ABI entry points,
Swift, SessionPool, and network authentication.

## Decision

The registry adds `register_or_reuse_unknown_challenge`. Existing `register`
remains available with its original create-new semantics so existing lifecycle
tests and callers are not silently changed. The checked handler's
`HostKeyChallengeService` uses the deduplicating method by default.

## Equivalence Key

Two pending challenges are equivalent only when all of these values match:

- normalized `HostIdentity`, including port and lookup token;
- normalized Host Key algorithm;
- SHA-256 Host Key fingerprint;
- opaque `TrustStoreGeneration`.

The original host spelling and request ID are not part of equivalence. DNS and
IP identities remain separate, as do default and non-default ports. Store
generation is mandatory so a request created against changed trust contents
cannot attach to a stale challenge.

The equivalence key contains no complete public key, file path, credentials,
private key, passphrase, or token. Its debug representation uses only normalized
identity, algorithm, fingerprint, and an opaque generation marker.

## Related Requests

Each deduplicated pending challenge stores a bounded set of distinct related
request IDs with creation times. The default limit is 16 and the hard
configuration maximum is 256. Request IDs retain the existing 256-byte and
control-character validation.

Repeated request IDs are idempotent. A new distinct request beyond the limit
returns `RelatedRequestLimitReached`; the registry does not evict an existing
request or allocate an additional challenge. The full related-request list is
never serialized or exposed to Swift. Only a count is exposed.

Every registration result carries the current caller's request ID, even when
the challenge ID was created by another request. Lifecycle operations such as
accept-and-persist remain correlated primarily by challenge ID because their
existing C ABI does not accept a new request ID.

## Capacity Ordering

Expired entries are cleaned first. Equivalence lookup occurs before global and
per-host capacity checks, so an equivalent request can reuse an existing entry
when the registry is full. A non-equivalent request remains subject to both
limits. Reuse does not increase pending challenge count.

## Lifecycle and Index Integrity

The registry maintains a second map from equivalence key to challenge ID. A
single internal removal path validates and removes both the pending record and
its index entry. It is used for:

- Pending to Accepted;
- Pending to Persisted;
- Pending to Rejected;
- Pending to Expired.

If tombstone creation fails, both pending record and equivalence index are
restored. A CAS binding mismatch occurs before removal, leaving both intact.
Missing or conflicting index entries return
`EquivalentChallengeIndexCorrupt` and fail closed.

Rejected, accepted, persisted, and expired tombstones remain keyed by their old
challenge IDs only. A later equivalent request may create a fresh challenge ID;
resolved IDs are never reused.

## Wire Compatibility

The challenge JSON payload gains two additive fields:

- `reused_existing_challenge`
- `related_request_count`

No existing field or kind changes. Missing fields decode to `false` and `0`,
preserving schema-version-1 compatibility. The payload never includes the
related-request list, complete public key, Known Hosts path, or credentials.

`related_request_limit_reached` is added as a stable error code. Internal index
corruption maps to the existing internal-error class rather than exposing
registry details.

## Why Changed and Revoked Are Not Deduplicated Here

Only `HostKeyVerificationDecision::Challenge` for an unknown key can enter this
registry. Changed and revoked keys remain structured blocked results and never
gain an acceptable pending challenge.

## Testing

Tests cover every equivalence component, normalized host aliases, DNS/IP and
port isolation, idempotent request IDs, request limits, capacity ordering,
accept/reject/persist/expire cleanup, CAS mismatch preservation, service-level
reuse, additive JSON fields, legacy JSON decoding, and sensitive-data
exclusion.

## Rollback

The checked handler can temporarily return to create-new registration by
calling the retained `register` API. Removing the equivalence index does not
change challenge IDs already persisted in Known Hosts because pending
challenges are memory-only. Wire consumers may ignore the two additive fields.

## Next Step

A2.3b-pre2 may now implement the checked-connect coordinator's trust-store
generation recheck before authentication. No checked test-connection C ABI
should be exposed until that recheck passes its fail-closed tests.
