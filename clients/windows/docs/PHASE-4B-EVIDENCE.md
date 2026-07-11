# Phase 4B Evidence: Workspace Tab Foundation

## Scope

Phase 4B introduces the Windows workspace tab foundation needed before moving
terminal, SFTP, monitor, Docker, and snippet runtime state into fully independent
per-tab sessions.

This phase intentionally keeps the runtime single-active. It prevents unsafe tab
switches while a connection or channel is active, avoiding UI/runtime mismatch
while the next phase extracts runtime state into per-tab containers.

## Implemented

- Added `WorkspaceTabViewModel` with tab identity, asset identity, credential
  identity, title, endpoint, host, port, and username draft state.
- Added workspace tab collection and selected-tab state to the main Windows
  view model.
- Added open-tab and close-tab commands.
- Synchronized current connection draft edits into the active tab.
- Restored draft state and cleared password input when switching tabs.
- Blocked tab open, close, and switch actions during active runtime.
- Added a WinUI workspace tab strip above the terminal pane.
- Added right-panel workspace tab count summary.

## Safety Review

- Passwords are not stored in workspace tab state.
- Switching tabs clears password input.
- Active SSH/SFTP/terminal runtime cannot be visually switched into another
  draft tab.
- Closing the last tab resets to a clean draft instead of leaving a null
  workspace.

## Verification

- Local Windows-client toolchain: passed.
- Local security/static checks: passed.
- Local tests: passed, 60 total.
- Remote Windows-host full toolchain: passed.
- Remote Windows-host full WinUI/XAML build: passed.

## Remaining Work

- Extract terminal, SFTP, host-key challenge, command history, and runtime
  status into per-tab session state.
- Add keyboard accelerators for new/close/switch tab parity.
