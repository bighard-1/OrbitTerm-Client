# Phase 4F Evidence: Menu and Command Entry Points

## Scope

Phase 4F adds a native Windows command surface for the capabilities already
implemented in previous phases. This makes the Windows client more practical for
daily testing and moves it closer to the macOS client's menu-driven tab
workflow.

## Implemented

- Added a WinUI `MenuBar` above the workstation layout.
- Added Workspace menu entries:
  - New Tab
  - Close Tab
  - Disconnect and Close Tab
  - Tab 1 through Tab 9
- Added Session menu entries:
  - Connect
  - End Session
  - Trust Host
- Added Terminal menu entries:
  - Open Terminal
  - Close Terminal
  - Clear Terminal
  - Copy Transcript
- Added SFTP menu entries:
  - Open SFTP
  - List Directory
  - Preview Text
- Added Assets menu entries:
  - New Asset
  - Save Asset
  - Delete Asset
- Added indexed tab selection via `Ctrl+1` through `Ctrl+9`.
- Added `SelectWorkspaceTabAt` to keep menu tab selection behavior testable.

## Safety Review

- Menu entries reuse existing commands instead of duplicating session logic.
- Copy transcript continues through the existing redaction-neutral visible
  transcript path.
- Indexed tab selection ignores invalid indexes without changing state.
- No password or credential material is stored in menus or command handlers.

## Verification

- Local Windows-client toolchain: passed.
- Local security/static checks: passed.
- Local tests: passed, 64 total.
- Remote Windows-host full toolchain: passed.
- Remote Windows-host full WinUI/XAML build: passed.

## Remaining Work

- Add disabled/checked visual state for indexed tab menu entries.
- Add direct menu entries for future Docker, monitor, snippets, and diagnostics
  panels as those Windows features reach parity.
