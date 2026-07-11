# Phase 4D Evidence: Per-Tab Live Session Ownership

## Scope

Phase 4D moves Windows live session ownership into workspace tabs. The previous
phase preserved visible state snapshots; this phase lets each tab retain its own
workspace identity and live channel references while users switch between tabs.

## Implemented

- Added per-tab `WorkspaceId`.
- Added per-tab live state for connection status, host-key challenge, terminal
  lease, and SFTP lease.
- Updated connect, trust-host, open terminal, open SFTP, terminal write, close
  terminal, and end session paths to use the active tab's workspace and leases.
- Allowed switching away from a connected tab and returning to restore its live
  session state.
- Kept close-tab disabled when the selected tab has an active connection,
  host-key challenge, terminal channel, or SFTP channel.
- Routed terminal output to the owning tab using workspace id, server id, and
  terminal channel id.
- Preserved current visible terminal behavior for the active tab while appending
  background output to the owning inactive tab.

## Safety Review

- Passwords still are not stored in tabs or live snapshots.
- Live channels are restored only from the owning tab.
- Closing active live sessions is not implicit; the user must end the session
  before closing that tab.
- Background terminal output cannot appear in the wrong visible tab.
- Test terminal channels now use unique channel ids to avoid masking routing
  mistakes.

## Verification

- Local Windows-client toolchain: passed.
- Local security/static checks: passed.
- Local tests: passed, 61 total.
- Remote Windows-host full toolchain: passed.
- Remote Windows-host full WinUI/XAML build: passed.

## Remaining Work

- Add explicit close-tab-with-disconnect workflow after a confirmation prompt.
- Add keyboard accelerators for tab switching parity.
- Expand per-tab SFTP and terminal management toward multiple channels per tab.
