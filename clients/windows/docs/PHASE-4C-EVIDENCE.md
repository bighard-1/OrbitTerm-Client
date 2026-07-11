# Phase 4C Evidence: Workspace Tab Runtime Snapshot

## Scope

Phase 4C preserves visible runtime state per Windows workspace tab while keeping
live SSH/SFTP/terminal leases single-active. This is a deliberate transition
step: it prevents state loss during tab switching and prepares for true per-tab
sessions without mixing live channels between tabs.

## Implemented

- Extended `WorkspaceTabViewModel` with terminal output, command history,
  command input, SFTP browser state, text preview state, status text,
  security text, paste status, session summary, and auto-scroll preference.
- Added snapshot save/restore paths to `MainWindowViewModel`.
- Switching tabs now saves the current tab state before restoring the selected
  tab state.
- Restored tab state rehydrates terminal output, command history, SFTP path,
  SFTP listing, preview text, and visible summaries.
- Passwords are still cleared on tab restore and are not stored in tab state.
- Live leases and host-key challenges remain outside snapshots.

## Safety Review

- No password, private key, passphrase, host-key challenge, verified session
  lease, terminal lease, or SFTP lease is captured into tab snapshots.
- Active runtime tab switching remains blocked.
- Snapshot restoration uses existing bounded terminal output rules.
- The implementation keeps one source of truth for visible collections by
  copying snapshots into the existing observable collections, avoiding nested UI
  collection bindings.

## Verification

- Local Windows-client toolchain: passed.
- Local security/static checks: passed.
- Local tests: passed, 61 total.
- Remote Windows-host full toolchain: passed.
- Remote Windows-host full WinUI/XAML build: passed.

## Remaining Work

- Move live verified session, host-key challenge, terminal lease, and SFTP lease
  ownership into per-tab session state.
- Add safe tab switching among multiple active sessions after per-tab leases are
  isolated.
