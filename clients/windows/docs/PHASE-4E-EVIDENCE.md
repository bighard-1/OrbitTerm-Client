# Phase 4E Evidence: Safe Active Tab Close and Keyboard Entry Points

## Scope

Phase 4E improves the Windows tab workflow for real testing. Phase 4D allowed
tabs to own live sessions; this phase adds an explicit safe close path for tabs
that still own runtime and introduces keyboard accelerators for common tab
actions.

## Implemented

- Added `DisconnectAndCloseWorkspaceTabCommand`.
- Kept normal close-tab disabled for tabs with an active connection, host-key
  challenge, terminal channel, or SFTP channel.
- Disconnect-and-close uses the existing `EndSessionCoreAsync` shutdown path
  before removing the selected tab.
- Closing the last tab through disconnect-and-close creates a clean draft tab.
- Added WinUI keyboard accelerators:
  - `Ctrl+T` opens a workspace tab.
  - `Ctrl+W` closes an inactive workspace tab.
  - `Ctrl+Shift+W` disconnects and closes an active workspace tab.
- Added an explicit disconnect-and-close icon button to the tab strip.

## Safety Review

- Active tabs are never closed silently.
- The disconnect path closes an open terminal channel before ending the verified
  session.
- SFTP and host-key state are cleared through the same session shutdown path
  used by the End Session command.
- Password state is not copied into tabs or evidence.

## Verification

- Local Windows-client toolchain: passed.
- Local security/static checks: passed.
- Local tests: passed, 63 total.
- Remote Windows-host full toolchain: passed.
- Remote Windows-host full WinUI/XAML build: passed.

## Remaining Work

- Add visible menu bar commands for tab actions.
- Add direct tab switching accelerators.
- Add a confirmation dialog once destructive close actions become user-facing
  beyond personal testing.
