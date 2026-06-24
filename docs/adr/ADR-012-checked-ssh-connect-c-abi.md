# ADR-012: Checked SSH Connect C ABI

- Status: Accepted for A2.3d
- Date: 2026-06-21
- Scope: Additive checked SSH connection and verified SessionPool insertion

## Context

A2.3b proved the real TCP/KEX, Host Key verification, structured challenge,
and pre-authentication trust-store generation flow through a test-only C ABI.
A2.3c then made SessionPool keys and metadata security-generation aware so a
checked request cannot reuse an accept-all connection.

The legacy `orbit_ssh_connect` still uses `OrbitSshClientHandler`, whose
`check_server_key` returns `Ok(true)`. Changing that API in this patch would
combine protocol migration with client migration and would remove the current
rollback boundary. A separate checked connection is therefore added first.

## Decision

Add the following versioned, additive C ABI:

```c
char *orbit_ssh_connect_checked_v1(
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

It returns schema-version-1 Host Key JSON envelopes. Rust owns returned
strings; callers release them with `orbit_free_string`. The legacy symbol,
arguments, `OK:`/`ERR:` response, and behavior remain unchanged.

## End-to-End Flow

1. Copy and validate all C strings before asynchronous work. Host, username,
   OrbitTerm Known Hosts path, port, credentials, and request ID use the same
   validation as the checked test connection.
2. Load the OrbitTerm Known Hosts store and compute `TrustStoreGeneration`.
3. Reuse an Active verified session only when HostIdentity, username, and
   trust-store generation match. Legacy sessions are ignored.
4. If no candidate exists, use `CheckedHostKeyHandler` for real TCP/KEX.
5. Unknown registers or reuses a bounded pending challenge and returns
   `host_key_challenge`. Changed, Revoked, and unsupported records return
   `host_key_blocked`. None of these paths performs authentication.
6. Trusted KEX is followed by `CheckedConnectCoordinator` reloading Known
   Hosts. A changed generation is reverified. Only a still-Trusted key reaches
   authentication.
7. Derive the exact `SessionSecurityGeneration::HostKeyVerified`, enter its
   per-key creation gate, and recheck the pool before authentication.
8. Authenticate private-key first, optionally falling back to password under
   the existing policy. Authentication has a 15-second timeout.
9. Insert the checked russh handle as an Active verified base session and
   return `connected` with session ID, normalized identity, algorithm,
   SHA-256 fingerprint, and `host_key_verified` generation summary.

The checked test connection and checked reusable connection share the KEX and
pre-authentication preparation component. This avoids duplicated security
logic while keeping their post-gate behavior distinct.

## SessionPool Storage

russh includes the Handler type in `client::Handle`. SessionPool therefore
stores a small internal `OrbitSshHandle` enum with legacy and checked variants.
It exposes only the common transport operations needed by existing call sites:
closed-state check, session-channel opening, and disconnect.

Legacy creation wraps only `OrbitSshClientHandler`; checked insertion wraps
only `CheckedHostKeyHandler`. `BaseSessionKey` still includes the complete
security generation, so neither path can locate or replace the other.

Before KEX, reuse is permitted only for an Active session whose opaque Store
generation equals the current file content. After KEX the exact algorithm and
fingerprint generation is gated and rechecked. Draining, Terminating, Closed,
or stale transports are skipped rather than reused.

## Authentication and Resource Safety

No Host Key challenge keeps a socket open and Rust never waits for UI. Unknown
connections end after KEX error propagation; the user separately calls the
existing accept-and-persist API and then starts a new checked connection.

Connect/KEX and authentication each use 15-second timeouts. A prepared handle
is best-effort disconnected on authentication, pool-gate, or exact-lookup
failure. A failed insertion drops the owned russh handle and cannot publish a
partial base session. Connected JSON is preflight-serialized; an envelope
construction or serialization failure releases the newly acquired pool
reference before returning an error.

## Error Mapping

Host Key challenges and blocks retain their dedicated JSON kinds. Network/KEX,
authentication, timeout, and SessionPool failures use distinct stable codes:

- `ssh_connect_failed`;
- `ssh_auth_failed`;
- `ssh_timeout`;
- `session_pool_failed`.

Store and Host Key errors continue to use the existing structured mappings.
No caller needs to parse natural-language errors.

## Sensitive Information

JSON, Debug, Display, and errors exclude passwords, private keys,
passphrases, complete public keys, tokens, and the Known Hosts path. The
connected payload exposes only HostIdentity fields, algorithm, SHA-256
fingerprint, session ID, and a coarse verified-generation label.

## Non-Goals

This patch does not:

- modify Swift, Android, or Go;
- change or remove legacy `orbit_ssh_connect` or its accept-all Handler;
- migrate SFTP, Monitor, Docker, batch command, or Apple CBridge call sites;
- write Known Hosts during connect;
- wait for Host Key UI or retain half-open connections;
- replace Changed keys, add ProxyJump, alter RSA policy, or add terminal UI.

Apple CBridge header synchronization remains a separate A2.4 client-integration
task. Release gating and final removal or redirection of legacy accept-all are
also separate release-blocking work.

## Testing

Default tests cover additive ABI input validation, null and invalid UTF-8
handling, request-ID correlation, challenge/blocked JSON kinds, authentication
versus SessionPool error codes, connected payload redaction, security-generation
payload construction, header preservation, and all prior SessionPool isolation
tests. Existing checked test and legacy tests remain regression gates.

An ignored OpenSSH smoke test uses the same `ORBITTERM_TEST_SSH_*` environment
variables as ADR-010. It accepts Connected, Challenge, or Blocked as valid
protocol outcomes and never runs by default.

CI additionally checks the C11 header and exported dynamic-library symbol.

## Rollback

Rollback removes only the new `_v1` symbol, checked-connect modules, checked
handle variant, and additive error code. It does not delete or migrate Known
Hosts data, challenge records, session IDs, or old ABI symbols. Existing
legacy clients continue unchanged throughout this stage.

Rollback is a development boundary, not a release security policy. A release
must not use the legacy accept-all path after the later build gate is enabled.

## Follow-up

A2.3e must inventory and cover independent SFTP, Monitor, Docker, and command
connection paths. A2.4 must synchronize the Apple bridge, decode JSON, show
Host Key UI, call accept-and-persist, and retry checked connect. A later release
gate must make checked behavior mandatory and prevent `Ok(true)` from shipping.
