# ADR-021: Swift Real Checked FFI Client

- Status: Accepted for A2.4c-0
- Date: 2026-06-22
- Scope: Real Apple checked-ABI adapter without business-path migration

## Context

A2.4a established schema-versioned Swift DTOs, string-backed typed IDs, and a
forwarding Apple C header. A2.4b added a fake-driven `HostKeyTrustCoordinator`
and Host Key UI skeleton. Rust now also exposes a checked PTY ABI with the
`terminal_channel_opened` result kind.

The coordinator still has no production `CheckedFFIClient`. Connecting it
directly to C while simultaneously changing SessionManager would combine FFI
ownership, protocol decoding, credentials, UI state, and production routing in
one risky patch. This stage therefore implements the real adapter and tests its
boundary without installing it in any user flow.

## Decision

Add `OrbitCoreCheckedFFIClient` as an actor implementing `CheckedFFIClient`.
Its live function table calls only:

- `orbit_ssh_connect_checked_v1`;
- `orbit_hostkey_challenge_accept_and_persist_v1`;
- `orbit_terminal_open_checked_v1`.

No method calls legacy SSH, generic `orbit_request_channel`, legacy SFTP, or
another fallback. The actor is not constructed by SessionManager or a service
in this patch, so production behavior remains unchanged.

SFTP, Monitor, and Docker thin methods are deferred to their service migration
patches. Their DTOs already exist, but exposing unused adapter surface here
would enlarge the review and test matrix without reducing a current user-path
risk.

## Terminal Payload

Add `terminal_channel_opened` to `CheckedFFIResultKind` and add
`TerminalChannelOpenedPayload`. It decodes:

- `base_session_id` as `BaseSessionID`;
- `terminal_channel_id` as `TerminalChannelID`;
- only `host_key_verified` security generation;
- `cols` and `rows` in `1...1000`.

Both IDs remain canonical decimal strings and never pass through `Double`.
Unknown additive JSON fields are ignored. An unknown generation, invalid ID,
zero dimension, or oversized dimension fails closed.

## C String Ownership

`OrbitCStringResultReader` receives the owned C pointer, installs `defer` for
the injected releaser, copies bytes into a Swift `String`, and validates UTF-8.
Null returns and invalid UTF-8 are structured client errors. Decode success,
decode failure, and invalid UTF-8 each release a non-null pointer exactly once.

The production releaser is `orbit_free_string`. No pointer or borrowed C input
is retained after a call. Unit tests inject a counting allocator/releaser and
do not link the live function table.

## Checked Connect

`connectChecked` resolves an ephemeral credential value from a
`CredentialAccessReference`, obtains the private Known Hosts path from its
provider, and calls `orbit_ssh_connect_checked_v1`. Credentials are local to
the invocation and are not actor properties.

The response must use schema version 1 and exactly match the supplied request
ID. Dispatch is structural: `connected`, `host_key_challenge`,
`host_key_blocked`, and `error` remain distinct. Unknown or unrelated kinds
fail closed. The adapter never parses `OK:`, `ERR:`, or natural-language error
messages.

## Accept and Persist Correlation

The current Rust ABI is:

```c
char *orbit_hostkey_challenge_accept_and_persist_v1(
    const char *challenge_id,
    const char *known_hosts_path,
    const char *comment
);
```

It has no new request-ID argument. A success response carries the request ID
that originally registered the challenge. Some persistence failures carry a
null request ID but retain `challenge_id`.

The Swift protocol therefore carries two IDs:

- a fresh local persist-attempt ID used by the coordinator to reject late task
  completion;
- the original challenge request ID used to validate non-null Rust response
  correlation.

Success requires the original request ID and exact challenge ID. A null-ID
error is accepted only when its challenge ID exactly matches. Any non-null
mismatch, missing binding, or cross-challenge response fails closed. The
adapter returns the local attempt ID to the coordinator only after this Rust
binding has been validated. It does not fabricate or rewrite the JSON.

Persist success does not reconnect inside the adapter. The coordinator retains
ownership of that state transition.

## Known Hosts Path Provider

`KnownHostsPathProvider` makes path selection injectable. The default provider
uses:

```text
Application Support/OrbitTerm/Security/known_hosts
```

It never uses `~/.ssh/known_hosts` or a temporary directory and does not expose
the path in descriptions or errors. This patch computes the path but does not
create directories; the existing Rust persistence path remains responsible for
secure parent creation when the real flow is later enabled.

## Credentials

`CheckedCredentialProvider` returns `CheckedCredentials` only for one adapter
call. The adapter stores the provider, not a password, private key, or
passphrase. Call and credential Debug descriptions are redacted. Swift strings
cannot guarantee memory zeroization, so a future vault integration should
minimize copies and lifetime; this patch makes that lifetime explicit and
bounded to the invocation.

## Error Model and Logging

`CheckedFFIClientError` now distinguishes null pointer, invalid UTF-8, JSON
decode, request mismatch, unexpected/unknown kind, structured FFI payload,
invalid input, unsupported schema, and internal invariant failures. Its
description contains only stable codes.

The adapter never logs complete JSON, host-plus-credential context, password,
private key, passphrase, Known Hosts path, or full public key. Underlying
decoder and provider error text is not propagated.

## Testing Without Network

The adapter depends on an injected function table and C result reader. The
XCTest target compiles those abstractions but intentionally excludes the live
symbol-binding file. Tests return allocated fixture JSON and verify:

- terminal kind, typed IDs, generation, dimensions, and unknown fields;
- connect success/challenge/blocked/error dispatch;
- request mismatch and malformed JSON rejection;
- persist success and null-request error challenge binding;
- terminal success, error, unexpected kind, and unknown kind;
- null/invalid UTF-8 handling;
- exactly-once release, including decode failures;
- redacted errors and provider paths.

The macOS and iOS app targets compile and link the live C functions, proving
the bridge signatures without executing them. No XCTest opens a socket, writes
Known Hosts, or invokes a Rust networking symbol.

## Follow-up

The next patch may construct this adapter behind a Debug/Internal-only
SessionManager route and inject an existing CredentialVault-backed provider.
It must keep the legacy path explicit, never fallback after a checked error,
and gate terminal creation on `terminal_channel_opened`.

Subsequent service patches can add checked SFTP, Monitor, and Docker adapter
methods as each business service migrates. Batch remains a separate release
blocker.

## Rollback

Rollback removes the adapter, live function table, providers, terminal DTO,
new tests, and the coordinator protocol-parameter adjustment. SessionManager
and all service behavior remain untouched, so rollback cannot change a user
connection path or Known Hosts data.
