# ADR-025: Docker Checked Service Migration

## Status

Accepted for the Debug/Internal migration path.

## Context

A2.4f removed Monitor's legacy reconnect and SFTP dependency. Docker remained a
critical bypass. Swift treated an SFTP channel as its Docker connection, called
legacy Docker functions with that ID, and used generic remote exec for rename
and update. The standalone Docker view could also read credentials from the
vault and create an independent legacy connection.

Rust already exposes checked list, stats, logs, and action functions. Each
function accepts a `HostKeyVerified` base-session ID, opens only checked exec
channels, and returns a versioned JSON envelope. Rust has typed rename and
update internals, but those operations do not yet have C ABI functions.

## Decision

### Checked adapter

`OrbitCoreCheckedFFIClient` provides four methods backed exclusively by:

- `orbit_docker_list_checked_v1`
- `orbit_docker_stats_checked_v1`
- `orbit_docker_logs_checked_v1`
- `orbit_docker_action_checked_v1`

Every call uses `BaseSessionID` and a fresh request ID. The adapter validates
the response kind, request ID, returned base-session ID, and, where applicable,
container ID and action. Container IDs, action values, and log-tail limits are
validated before crossing the C boundary. It never calls legacy Docker, SFTP,
or generic exec.

### Typed operation service

`CheckedDockerBinding` contains only a workspace ID and `BaseSessionID`.
`CheckedDockerOperationService` does not retain a host, credential reference,
SFTP ID, or known-hosts path. It provides typed refresh, logs, and action
operations. List and stats use separate fresh request IDs so responses cannot
cross between operations.

Docker does not trigger Host Key UI, create SSH connections, or reconnect. It
requires SessionManager to hand it an existing `VerifiedWorkspaceSession`.

### Refresh semantics

Starting checked Docker performs one list/stats refresh and then starts a
bounded periodic refresh task. The task retains only `CheckedDockerBinding`.
Each list and stats call has a new request ID. The first checked failure stops
the loop and marks Docker disconnected. Cancellation invalidates the run ID, so
a late response cannot update UI state. No failure can fall back to legacy or
create another transport.

Logs and actions generate their own request IDs. Docker log content is returned
to the explicit logs UI but is never included in debug descriptions or logged
as a complete JSON payload.

### SessionManager and standalone Docker

The checked terminal flow still does not auto-start Docker. A user action asks
SessionManager for the current verified lease and then starts Docker from that
base session. A missing or closed lease fails closed without affecting the
terminal session.

In checked mode, standalone Docker hides host, username, and password entry and
does not run vault-backed auto-binding. It can use only the current workspace's
verified session. Without one, it displays a verified-session requirement.

### Rename and update

Checked mode hides and disables rename/update because no typed C ABI exists.
The service also rejects direct rename/update calls before reaching generic
`orbit_exec_command`. It does not fall back to the legacy implementation. The
UI explains that these operations will return after the secure interface is
available.

A4-Docker-3 must expose the existing typed Rust rename/update operations as
additive checked C ABI before Swift re-enables these controls.

### Legacy compatibility

When `CheckedConnectionMode` is disabled, existing SFTP-backed Docker behavior,
legacy Docker calls, rename/update, and refresh behavior remain unchanged. This
compatibility is temporary and does not make legacy networking release-safe.

## Error handling

`CheckedDockerServiceError` distinguishes missing verified sessions, session
closure, request mismatch, unexpected kinds, invalid container IDs/actions,
cancellation, disabled rename/update, operation failure, and internal
invariants. Descriptions contain stable codes only and exclude credentials,
paths, container input, and log content.

## Scope

This change does not modify Rust, C headers, Batch, Host Key behavior, Android,
Go, or the Release default. Batch remains a separate critical bypass.

## Release gate

Before enabling checked mode in Release, CI must prove that Docker cannot call
legacy Docker functions, SFTP connect/channel APIs, generic exec, or vault-based
connection code. Legacy Docker networking must then fail closed or be removed
from the Release path.

## Testing

Injected function tables and scripted clients cover all four checked ABIs,
kind/request/base/container correlation, input rejection before FFI, fresh
request IDs, session closure, no Connect/SFTP calls, cancellation of late
responses, first-failure stop, legacy policy preservation, rename/update
disablement, and log/error redaction. Tests do not contact SSH or Docker.

## Follow-up

1. A4-Docker-3: additive typed checked rename/update C ABI.
2. Migrate Batch away from legacy SFTP and generic exec.
3. Implement the Release gate and disable legacy networking.
4. Remove the production Accept-All handler after every user path is checked.

## Rollback

Remove the checked Docker adapter/service/UI hooks and their Xcode project
references. The disabled-mode legacy path remains unchanged, so rollback does
not require Rust or ABI changes.
