# ADR-024: Monitor Checked Snapshot Migration

## Status

Accepted for the Debug/Internal migration path.

## Context

A2.4e moved SFTP in the checked path onto an existing `HostKeyVerified` base
session. Monitor remained a critical bypass: it sampled through a legacy SFTP
session, retained host and credential identifiers, and silently rebuilt an
Accept-All transport after repeated failures.

Rust already exposes `orbit_monitor_snapshot_checked_v1(base_session_id,
request_id)`. It opens checked exec channels from the verified base session and
returns one bounded snapshot. Swift therefore does not need a Monitor-specific
SSH or SFTP connection.

## Decision

### Adapter and typed binding

`OrbitCoreCheckedFFIClient.monitorSnapshotChecked` is the only checked Monitor
C boundary. It accepts `BaseSessionID`, creates no transport, decodes only the
`monitor_snapshot` envelope, and verifies both `request_id` and the returned
base session ID.

`CheckedMonitorBinding` contains only `workspaceID` and `BaseSessionID`. It does
not contain a host, username, credential reference, SFTP ID, or known-hosts
path. `CheckedMonitorSnapshotService` creates a fresh request ID for every
sample and maps stable FFI codes into `CheckedMonitorServiceError`.

### Polling semantics

Checked polling is explicit and starts only after SessionManager hands Monitor
an existing `VerifiedWorkspaceSession`. Each tick:

1. creates a new request ID;
2. calls the checked snapshot ABI;
3. verifies request and base-session correlation;
4. updates the UI from the typed payload.

The polling task retains only the typed binding. It never reads
`CredentialVault`, opens SFTP, or calls `orbit_fetch_system_stats`. Any checked
snapshot or channel-gate failure stops the loop. There is no retry that creates
a connection and no fallback to legacy Monitor. Cancellation invalidates a run
token, so a late response cannot update the UI.

Diagnostics are bounded enum values. Missing ping data remains `nil` and is
shown as unavailable; it is not converted into a transport failure. The full
stats JSON is not logged.

### SessionManager and standalone Monitor

The Debug/Internal SessionManager path exposes its verified lease to an
explicit Monitor start action. Monitor is still not auto-started by checked
terminal connection. A closed or missing verified base fails closed and leaves
the terminal session alone.

Standalone Monitor in checked mode does not present host or credential entry.
It can use only the current workspace's verified lease. Without one, it shows a
verified-session requirement and does not read the vault or silently connect.

### Legacy compatibility

When `CheckedConnectionMode` is disabled, existing Monitor targets, SFTP-based
sampling, and reconnect behavior remain unchanged. In checked mode, legacy
Monitor connect overloads reject before credential or SFTP access. This is a
migration boundary, not the final release security switch.

## Error handling

Stable Swift errors distinguish missing verified sessions, session closure,
request mismatch, unexpected kinds, cancellation, invalid IDs, checked
snapshot failure, and internal invariants. Descriptions contain only stable
codes and exclude credentials, host-key material, paths, and complete payloads.

## Scope

This change does not modify Rust, C headers, Host Key behavior, Docker, Batch,
or the Release default. Docker and Batch remain separate migration blockers.

## Release gate

Before Release enables checked mode by default, CI must prove that Monitor
cannot call legacy stats, SFTP connect, generic SFTP channel requests, or
credential-backed reconnect in the Release path. Legacy Monitor networking must
then fail closed or be unavailable.

## Testing

Unit tests cover adapter kind/request/base correlation, fresh request IDs,
typed payloads, gate-error mapping, cancellation of late responses, stop on the
first failure, no connect/SFTP calls, legacy policy preservation, and redacted
errors. macOS and iOS Debug builds verify the SessionManager and UI integration.
Tests use injected clients and never contact an SSH server.

## Follow-up

1. Migrate DockerService to the checked typed Docker ABI.
2. Replace Batch's legacy SFTP/generic exec path.
3. Implement the Release gate and disable legacy networking.
4. Remove the production Accept-All handler after every user path is checked.

## Rollback

Remove the checked Monitor adapter/service/UI start points and their project
references. The disabled-mode legacy implementation is unchanged, so rollback
does not require a Rust or ABI change.
