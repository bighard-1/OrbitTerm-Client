# ADR-010: Checked Test Connection C ABI

- Status: Accepted for A2.3b
- Date: 2026-06-21
- Scope: Additive test-only SSH connection C ABI

## Context

A2.3a introduced `CheckedHostKeyHandler` and its structured pre-authentication
errors. A2.3b-pre1 added bounded equivalent challenge reuse, and A2.3b-pre2
added the `CheckedConnectCoordinator` store-generation gate. None of those
components previously performed a real SSH handshake.

The ordinary `orbit_test_ssh_connection` and `orbit_ssh_connect` entry points
still use the legacy accept-all handler and return `OK:` / `ERR:` strings. This
patch deliberately does not modify them.

## Decision

Add a test-only, versioned C ABI entry:

```c
char *orbit_test_ssh_connection_checked_v1(
    const char *host,
    int32_t port,
    const char *username,
    const char *password,
    const char *private_key,
    const char *private_key_passphrase,
    int32_t allow_password_fallback,
    const char *known_hosts_path,
    const char *request_id
);
```

The function returns the existing schema-version-1 Host Key JSON envelope. The
returned C string is Rust-owned and must be released with
`orbit_free_string`. The API is additive and does not replace or alter any old
symbol.

`request_id` is required, bounded to 256 bytes, and rejects control characters.
This provides deterministic correlation for concurrent test requests and
deduplicated challenges. Credential pointers may be null and are treated as
empty values, but at least one password or private key is required.

## Why Test Connection First

The checked test path performs no terminal setup, channel creation, SFTP,
Docker, Monitor, or SessionPool insertion. It is therefore the narrowest real
network path for proving KEX verification and error propagation before
changing reusable production sessions. Failure or rollback cannot strand a
stored session or change ordinary client behavior.

## Flow

1. Parse and validate host, port, username, credentials, OrbitTerm Known Hosts
   path, and request ID.
2. Load the initial `KnownHostsStore` and compute `TrustStoreGeneration` through
   `CheckedConnectCoordinator`.
3. Run real TCP and SSH KEX with `CheckedHostKeyHandler`.
4. Return an unknown-key challenge or blocked result directly from the handler
   without authentication.
5. For a trusted KEX result, reload Known Hosts at the authentication boundary.
6. Allow authentication only if the generation is unchanged or revalidation
   against the changed store remains trusted.
7. Test authentication, disconnect on completion, and discard the handle.

The function never writes Known Hosts. Trust remains an explicit second call
to `orbit_hostkey_challenge_accept_and_persist_v1`, followed by a fresh checked
test request.

## Host Key Outcomes

| Condition | JSON result | Authentication |
| --- | --- | --- |
| Unknown | `host_key_challenge` | Not attempted |
| Changed | `host_key_blocked` | Not attempted |
| Revoked | `host_key_blocked` | Not attempted |
| Unsupported / certificate authority | `host_key_blocked` | Not attempted |
| Store failure or invalid verification state | Error envelope | Not attempted |
| Trusted and authenticated | `connection_test_succeeded` | Completed once |

The handler never waits for UI and no half-open connection is retained while a
challenge is displayed. The caller persists trust separately and reconnects.

## Authentication Policy

Authentication preserves the legacy test order without sharing its lossy
error wrapper:

- a supplied private key is tried first;
- a rejected key falls back to password only when explicitly enabled;
- password is used directly when no private key is supplied;
- missing credentials are rejected before network activity.

Invalid key input, rejected credentials, and authentication protocol failures
map to `ssh_auth_failed`. They remain distinct from network/KEX failure and
Host Key decisions. Credentials are not logged and are excluded from result,
error, and debug representations.

## Store Generation Gate

The coordinator reloads the same caller-provided file immediately before
authentication. Unknown after a generation change fails closed and does not
create a late challenge. Changed, revoked, unsupported, malformed, empty-slot,
and reload-error outcomes all prevent authentication. A successful response
contains only the verified Host Key summary, never the complete public key or
store generation digest.

## Known Hosts Path

The path must be absolute, must have an OrbitTerm component, and must not pass
through a lexical or canonical `.ssh` parent. Existing file and direct-parent
symbolic links are rejected by the checked request validator. The path is
revalidated on both the initial and pre-authentication reload. It is passed
into Rust by the platform layer but is never returned in JSON or error text.
The API does not default to or modify system `~/.ssh/known_hosts`.

## Timeout and Cancellation Boundary

The checked path uses the existing global Tokio runtime. TCP plus KEX has a
15-second timeout and authentication has a separate 15-second timeout. A
best-effort disconnect is itself bounded to 2 seconds. Dropping a timed-out
future and handle cancels the request from the caller's perspective; no custom
background task, timer thread, unbounded queue, or stored socket is created.

Timeout is a distinct `ssh_timeout` error code. Authentication and network/KEX
failures use `ssh_auth_failed` and `ssh_connect_failed` respectively.

## JSON and Error Mapping

The checked API never returns legacy `OK:` or `ERR:` text. Structured handler
challenge and blocked variants map directly to their JSON result kinds.
Verifier, registry, Store, coordinator, network, authentication, timeout, and
input failures map to stable error codes and bounded detail codes without
natural-language parsing.

JSON excludes passwords, private keys, passphrases, credential tokens,
complete server public keys, and the local Known Hosts path. Panics are caught
at the C boundary by the shared FFI response wrapper.

## Header Strategy

`orbit-core/include/orbit_core.h` declares the new symbol. The legacy symbols
remain unchanged. The Apple copy at `OrbitTerm/CBridge/orbit_core.h` is not
modified in this patch because Swift is outside A2.3b. Synchronizing that
header and adding Swift Codable/UI consumption is an explicit A2.4 prerequisite.

## Testing

Default Rust tests cover null and invalid UTF-8 inputs, invalid ports, missing
credentials, request correlation, C string release, challenge and blocked JSON,
network/auth/timeout distinction, Store failures, slot-empty fail-closed
mapping, authentication-gate invocation counts, path and credential redaction,
and header compatibility.

An ignored OpenSSH smoke test is available for manual environments:

```bash
ORBITTERM_TEST_SSH_HOST=127.0.0.1 \
ORBITTERM_TEST_SSH_PORT=2222 \
ORBITTERM_TEST_SSH_USERNAME=test \
ORBITTERM_TEST_SSH_PASSWORD=secret \
ORBITTERM_TEST_KNOWN_HOSTS_PATH=/tmp/OrbitTerm-test/known_hosts \
cargo test openssh_checked_test_connection_smoke -- --ignored --nocapture
```

The default test suite never requires a server, container, network, or local
SSH daemon.

## Follow-up

A2.3c will bind `SessionSecurityGeneration` to SessionPool keys and reject
legacy session reuse. A2.3d may then add ordinary checked connect. SFTP,
Monitor, and Docker must be migrated only after the pool boundary is enforced.
A2.4 will synchronize the Apple bridge header and implement the UI flow.

## Rollback

The new C symbol, two checked-test modules, tests, and this ADR can be removed
without changing old ABI behavior, the Known Hosts format, persisted trust,
SessionPool, or ordinary connections. Existing trust records are not deleted
or rewritten during rollback.
