# Phase 4G Evidence: SFTP Browse Operations Foundation

Date: 2026-07-03

## Scope

- Added safe SFTP directory selection and open-selected behavior.
- Added parent-directory and refresh commands.
- Added SFTP menu and runtime-panel entry points for parent, refresh, and
  open-selected operations.
- Expanded directory item view models with normalized path, kind text, and a
  directory flag.

## Safety Boundary

- Windows production code still uses only checked SFTP open, list-directory,
  and read-text APIs.
- Legacy upload, download, remove, rename, mkdir, chmod, and write APIs remain
  disconnected from Windows production code until checked wrappers exist.
- Remote child paths are created only from a previously normalized directory
  path plus a safe child name. Names containing separators, parent traversal,
  empty names, or control characters are not made actionable.
- Text preview remains read-only.

## Verification

- Local Windows-client toolchain checks passed.
- Local non-UI Windows projects built successfully.
- Local Windows security/unit tests passed: 65/65.
- Remote Windows-host full WinUI validation passed.

## Review Notes

- No SFTP transfer or edit UI was added because the checked FFI layer currently
  exposes only open, list, and read-text operations to Windows.
- Sensitive scan did not find real remote host credentials in project files.
