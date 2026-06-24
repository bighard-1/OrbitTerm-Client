# ADR-022: SessionManager Checked Connect Debug Path

- Status: Accepted for A2.4c
- Date: 2026-06-22
- Scope: Debug/Internal checked SSH and terminal orchestration

## Context

Rust exposes checked SSH connect and checked PTY ABIs. Swift has schema-v1 DTOs,
typed IDs, a Host Key trust coordinator and UI skeleton, and a real checked FFI
adapter. The production `SessionManager` still opens an Accept-All base session,
uses generic `orbit_request_channel("pty")`, and then starts SFTP, Monitor, and
Docker. Switching all of that at once would mix trust UI, terminal migration,
and three unresolved side-service paths.

## Decision

Add a migration-only `CheckedConnectionMode` with `disabled` and
`debugInternalOnly`. `SessionManager.shared` uses `applicationDefault`:

```text
DEBUG && ORBITTERM_INTERNAL_CHECKED_CONNECTION -> debugInternalOnly
otherwise                                    -> disabled
```

The condition is compile-time only. It is not read from remote configuration,
user defaults, launch input, or another untrusted runtime source. Normal Debug
and every Release build remain disabled unless an internal Debug configuration
explicitly defines the condition. Tests inject both enum values into a small
dispatcher. This flag is scaffolding for migration, not a permanent security
or release switch.

When disabled, `SessionManager.connect` enters the existing legacy body without
changing its connect, PTY, SFTP, Monitor, or Docker behavior. When enabled, it
returns into a separate checked method before any legacy credential read,
physical connect, or generic channel request.

## Checked Connect Flow

The checked path is:

```text
SessionManager
-> CheckedTerminalConnectionOrchestrator
-> HostKeyTrustCoordinator
-> OrbitCoreCheckedFFIClient.connectChecked
-> verified BaseSessionID
-> OrbitCoreCheckedFFIClient.openTerminalChecked
-> TerminalChannelID
```

The orchestrator is `@MainActor` and owns one coordinator. Direct trust succeeds
only after a checked terminal response with the expected request ID and matching
base session ID. Unknown hosts stop in awaiting-user-decision. Persist succeeds
before reconnect. Changed and revoked remain blocked. Store, authentication,
network, timeout, protocol, and client errors remain structured. No checked
failure calls the legacy connector.

Only one app-level Host Key presentation route may be active. A second connect
request is not allowed to replace it. Closing a workspace or disconnecting it
cancels the matching route, preventing late state from being installed into a
different tab.

## Host Key UI

`MainShellView` presents the existing `HostKeyTrustView` from
`SessionManager.checkedHostKeyRoute`. The view reads coordinator state only.
Trust, Retry Save, Cancel, and Close are routed back through SessionManager so
the terminal orchestration observes each result.

Unknown offers no Trust All. Changed and revoked offer no Accept Anyway. Save
failure retries only persistence. Dismissing the sheet cancels the flow. No UI
displays credentials or the Known Hosts path.

## Checked Terminal

The checked path calls `openTerminalChecked` with a fresh request ID and a safe
default size of 120 columns by 36 rows. It never calls `TerminalService.openPTY`
or generic `orbit_request_channel("pty")`. Existing split-terminal creation
still uses the generic API, so splitting is explicitly disabled for a checked
lease until a checked split API is wired through the same adapter.

A terminal-open failure retains the typed verified base lease for deterministic
cleanup but does not mark the workspace terminal connected or start any side
service.

## Typed Session State

`VerifiedWorkspaceSession` binds:

- workspace UUID;
- `BaseSessionID`;
- optional `TerminalChannelID`.

`WorkspaceSession` stores this lease separately from legacy IDs. Existing
terminal read, write, resize, callback, and disconnect APIs still accept
`UInt64`; therefore SessionManager performs an explicit conversion at that
compatibility boundary. The typed lease remains the authority for identifying
a checked workspace. SFTP IDs cannot be substituted for either typed field.

Multi-tab storage remains unchanged in this stage. Per-base callback lookup
continues to use the existing raw map after the explicit conversion.

## Credentials

`CredentialVaultCheckedProvider` resolves the opaque credential reference for
each adapter invocation and returns password/key material only to the adapter.
SessionManager and the orchestrator retain only the credential UUID and the
non-secret password-fallback policy. They do not log credentials, complete JSON,
or the Known Hosts path.

## Side-Service Gate

Checked workspaces do not automatically start SFTP, Monitor, Docker, or Batch.
The migration policy represents all four as disabled. A successful checked
terminal records that these services are pending migration. It does not allow a
SessionManager does not ask a side service to reconnect through its legacy
host-and-credential path. Direct legacy service UI remains reachable in this
migration stage and is a release blocker until each service patch lands.

Legacy workspaces retain their previous automatic service startup. Future
A2.4e, A2.4f, and A2.4g patches will migrate SFTP, Monitor, and Docker one at a
time using the verified base ID. Batch remains a release blocker.

## Error Handling

Coordinator states and stable Rust error codes determine behavior; no branch
parses natural-language messages. Host Key challenge, changed/revoked block,
save failure, authentication failure, network failure, timeout, terminal-open
failure, request mismatch, cancellation, and unknown protocol results remain
distinct fail-closed states. User-facing terminal text is generic and contains
no credential, complete JSON, public key, or trust-store path.

## Why Not Release Default

SFTP, Monitor, Docker, Batch, and release legacy gates remain incomplete.
Enabling checked terminal connection by default could leave users with a mixed
security model or silently reintroduce legacy reconnect through a side feature.
Release therefore remains on the unchanged legacy path during this migration
stage. This is not a claim that the legacy Release path is safe; A2.5 must make
legacy networking fail closed before security completion.

## Testing

Network-free XCTest uses the scripted checked client to cover:

- disabled/checked routing and no fallback;
- direct checked connect and typed terminal lease;
- challenge, cancel, persist/reconnect, and persist failure;
- changed, revoked, auth, network, and stale responses;
- terminal-open failure with a base-only typed lease;
- explicit side-service disablement.

The app targets compile the real adapter and SessionManager integration but
tests invoke no C networking symbol and write no Known Hosts file. macOS and iOS
Simulator Debug builds validate the production wiring.

## Follow-up

1. Migrate SFTP to `orbit_sftp_open_checked_v1` using the verified base ID.
2. Migrate Monitor snapshot polling and remove silent legacy reconnect.
3. Migrate Docker checked APIs and finish typed rename/update exposure.
4. Implement checked Batch command execution.
5. Add the Release gate and make every legacy networking entry fail closed.
6. Remove the production Accept-All handler after all callers migrate.

## Rollback

Remove the compile-time mode, checked orchestrator, typed lease, presentation
route, and SessionManager checked branch. Because `applicationDefault` is
disabled without the internal condition and the legacy body is retained, this
rollback does not require an ABI or trust-store migration.
