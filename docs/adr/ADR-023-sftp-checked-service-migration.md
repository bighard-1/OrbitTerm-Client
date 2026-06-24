# ADR-023: Swift Checked SFTP Service Migration

- Status: Accepted for A2.4e
- Date: 2026-06-22
- Scope: Debug/Internal checked SFTP path on Apple platforms

## Context

ADR-022 connected SessionManager to checked SSH and checked PTY behind a
compile-time Debug/Internal mode. SFTP remained a Critical bypass with three
Swift paths:

- standalone `orbit_sftp_connect` using host and credentials;
- generic `orbit_request_channel(base, "sftp")`;
- `SFTPBrowserView` silently reading CredentialVault and reconnecting by host.

All three could bypass the verified base-session requirement. Existing SFTP
list, transfer, edit, rename, delete, and directory ABIs operate on an SFTP
session ID and do not themselves need a new Rust API.

## Decision

Add `openSFTPChecked` to `CheckedFFIClient` and bind it only to:

```c
orbit_sftp_open_checked_v1(base_session_id, request_id)
```

The adapter receives `BaseSessionID`, verifies schema and request correlation,
requires `sftp_channel_opened`, verifies the returned base ID, and returns
`SFTPChannelOpenedPayload` with a typed `SFTPSessionID`. It does not accept a
host, username, password, private key, passphrase, or Known Hosts path. It does
not call legacy SFTP or generic channel APIs and has no fallback.

## Checked SFTP Service

`CheckedSFTPConnectionService` receives a verified base ID and an injected
checked client. It creates a fresh request ID and returns:

```text
CheckedSFTPConnection {
    workspaceID,
    BaseSessionID,
    SFTPSessionID
}
```

The service cannot perform physical SSH connect, read CredentialVault, trigger
Host Key UI, or reconnect. Request mismatch, unexpected kinds, closed sessions,
structured FFI errors, cancellation, and malformed responses remain typed
`CheckedSFTPServiceError` values.

## SessionManager Handoff

When the user opens SFTP, SessionManager evaluates `SFTPConnectionPolicy`:

- disabled migration mode retains the legacy behavior;
- Debug/Internal checked mode requires `VerifiedWorkspaceSession`;
- a verified lease passes only its typed `BaseSessionID` to the checked service;
- absence of a verified lease returns `requiresVerifiedSession`.

SFTP is still not opened during checked terminal connect. Navigation to the
SFTP browser is the explicit demand signal. A checked SFTP failure leaves the
terminal and verified base lease intact and does not call a legacy connector.

## Standalone SFTP

In checked mode, `SFTPBrowserView` does not display host, username, or password
fields and does not own a CredentialVault reference. Without an active verified
workspace it shows a requires-verified-session state and performs no connection.
With a verified workspace it requests checked SFTP from SessionManager.

This is enforced again inside `SFTPManager`: checked mode rejects both
host/credential `connect` and generic base-session `connect`. Hiding a UI alone
is not considered a sufficient security boundary.

Legacy mode keeps the existing standalone panel, mock behavior, Vault lookup,
`orbit_sftp_connect`, and generic base-session behavior. This is temporary and
remains subject to the future Release gate.

## Typed Operation Boundary

`SFTPManager` stores a checked connection separately from its legacy raw ID.
All list, upload, download, batch download, read, write, rename, delete, mkdir,
and chmod paths obtain their numeric handle through one operation boundary:

```text
checked SFTPSessionID -> explicit UInt64 conversion -> existing SFTP ABI
```

The checked path never substitutes `BaseSessionID` or `TerminalChannelID` for
the SFTP ID. Disconnect uses the same boundary and clears both typed and legacy
state. If initial directory refresh fails after opening a checked channel, the
channel is closed before state is cleared.

## Host Key and Credentials

SFTP does not implement Host Key UI and does not initiate checked SSH. It can
only consume a verified base lease created by SessionManager. Unknown, changed,
revoked, save failure, authentication failure, and cancellation are therefore
resolved before SFTP becomes available.

The checked SFTP service and manager receive no credentials and perform no
CredentialVault read. Complete JSON, credentials, Known Hosts paths, and public
keys are not logged or included in structured error descriptions.

## Error Handling

Stable Swift errors cover verified-session requirement, checked-open failure,
request mismatch, unexpected kind, legacy-disabled mode, closed session,
cancellation, invalid SFTP ID, unknown checked error, and invariant failure.
User-facing text is derived from the enum; control flow never parses localized
messages.

## Deferred Services

Monitor, Docker, and Batch are unchanged. Monitor still has legacy reconnect,
Docker still has legacy Swift service entry points, and Batch still depends on
legacy SFTP/generic exec. Each remains a Release blocker.

The recommended sequence is checked Monitor snapshot polling, checked Docker
service migration, checked Batch execution, then the Release gate that disables
all legacy networking.

## Testing

Network-free XCTest covers:

- adapter success, request mismatch, base mismatch, error and wrong kind;
- typed checked connection and typed SFTP ID;
- no checked/legacy SSH connect invocation by the checked SFTP service;
- closed-session and stale-response fail-closed behavior;
- checked policy rejection without a verified lease;
- unchanged legacy policy selection;
- stable redacted errors.

macOS and iOS Simulator builds compile the live `orbit_sftp_open_checked_v1`
binding without executing it. Tests perform no network connection, Vault read,
or Known Hosts write.

## Release Gate

This migration remains Debug/Internal-only because Monitor, Docker, Batch, and
the production Accept-All route are unresolved. Release must eventually prevent
legacy SSH and SFTP symbols from networking, verify all service entry points use
verified leases, and remove the production constant-accept handler.

## Rollback

Remove the checked adapter method, typed service and connection state,
SessionManager handoff, Browser checked presentation, and tests. Since the
compile-time application default remains disabled and legacy methods are
retained unchanged for disabled mode, rollback requires no ABI or stored-data
migration.
