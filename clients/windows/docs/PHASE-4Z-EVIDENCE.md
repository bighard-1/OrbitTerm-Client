# Phase 4Z Evidence: Checked Online Text Editing

## Scope

Phase 4Z adds guarded editing and recoverable saving for small UTF-8 regular files across the checked SFTP core, stable native ABI, Windows bridge, application orchestration layer, presentation model, and WinUI surface.

## Safety Boundary

- Editing is available only for a regular file opened from a checked directory listing. A manually entered preview path remains read-only because it has no trusted listing snapshot.
- Save accepts valid UTF-8 text without NUL bytes up to 2 MiB and passes bytes plus an explicit length through the native ABI.
- The original size, full Unix mode, modified time, and file type are validated again before replacement. Symbolic links and special files are rejected.
- Saving never truncates the original in place. The core exclusively creates a sibling `.orbitterm-new` file, copies the original permissions, writes the complete content, and then moves the original to `.orbitterm-backup` before promoting the new file.
- A failed promotion attempts to restore the backup immediately. Fixed recovery names keep the remaining artifact discoverable if both promotion and rollback fail.
- Existing recovery files block another save instead of being overwritten.
- Unsaved edits disable directory navigation, opening another entry, rename, delete, and permission changes. Revert explicitly restores the original editor content and re-enables those actions.
- After a successful save, the editor becomes read-only because the captured snapshot is intentionally stale; reopening the file obtains a fresh snapshot.

## Review Findings Resolved

- Initial dirty-state protection covered browse and refresh actions but did not cover rename, delete, or permission changes. Those mutation predicates now share the same dirty-state guard, and regression assertions verify both lock and revert behavior.
- Staging errors, stale snapshot detection, and first-rename failures now clean up the temporary file on a best-effort basis.
- Random recovery names were replaced with fixed sibling suffixes so an interrupted save leaves a deterministic recovery path rather than an orphan that is difficult to identify.
- Local macOS .NET execution was unavailable in the controlled workspace. Windows tests and the WinUI build were therefore rerun on the designated Windows host after the final review fix.

## Verification

- Full Rust core tests: 287 passed, 0 failed, 2 environment fixtures ignored.
- Rust formatting check: passed.
- Rust Clippy with warnings denied: passed.
- Windows automated tests: 73 passed, 0 failed, 0 skipped.
- Windows WinUI x64 Release build: passed.
- Windows static security and release gates: passed.
- Remote Windows x64 MSVC Debug build: passed.
- Remote Windows x64 MSVC Release build: passed and produced `orbit_core.dll`.
- Remote validation was confined to `D:\\Macmini2\\phase-4z-validate`; the uploaded archive was confined to `D:\\Macmini2\\orbitterm-phase-4z.zip`.

## Residual Boundary

SFTP v3 has no portable atomic compare-and-swap or exchange-rename operation. Snapshot validation greatly narrows stale writes, but another actor can still change the file after the final metadata check. The two renames also create a brief interval in which the original path is absent. If promotion and rollback both fail, the fixed `.orbitterm-backup` file is retained for manual recovery. A real end-to-end mutation test against each user SFTP server remains necessary because server rename, permission, and locking policies vary.
