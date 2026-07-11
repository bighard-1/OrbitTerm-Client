# Phase 4Y Evidence: Checked File Creation And Permissions

## Scope

Phase 4Y adds exclusive empty-file creation and snapshot-validated permission changes to the checked SFTP core, Windows native bridge, application orchestration layer, presentation model, and WinUI action surface.

## Safety Boundary

- Empty files are created with SFTP `CREATE | EXCLUDE | WRITE`; existing destinations are never truncated or overwritten.
- Permission changes use SFTP `SETSTAT` and never invoke a remote shell command.
- Chmod accepts only three or four octal permission digits and preserves the selected entry's regular-file or directory type bits.
- The selected size, full Unix mode, modified time, and directory type must still match before the operation proceeds.
- Symbolic links and other special file types are rejected to avoid changing a link target unexpectedly.
- The core reads metadata again after `SETSTAT` and fails the operation if the requested permission bits were not applied.
- Successful operations refresh the current directory before reporting completion.

## Review Findings Resolved

- The first WinUI validation command used the default `AnyCPU` target, which MSIX correctly rejects for an app-host executable. Validation was rerun with the intended `x64` and `win-x64` targets; no code workaround was introduced.
- Local macOS VSTest execution was blocked by the sandbox's local-socket policy. The same compiled test assembly was executed successfully on the Windows validation host.

## Verification

- Full Rust core tests: 286 passed, 0 failed, 2 environment fixtures ignored.
- Rust formatting check: passed.
- Rust Clippy with warnings denied: passed.
- Windows automated tests: 73 passed, 0 failed.
- Windows non-UI Release build: passed with 0 warnings and 0 errors.
- Windows WinUI x64 Release build: passed.
- Windows XAML structure validation: passed.
- Local and remote Windows static gates: passed.
- Diff whitespace check: passed.
- Remote Windows x64 MSVC Debug build: passed.
- Remote Windows x64 MSVC Release build: passed and produced `orbit_core.dll`.
- Remote validation was confined to `D:\\Macmini2\\phase-4y-validate`; the uploaded archive was confined to `D:\\Macmini2\\orbitterm-phase-4y.zip`.

## Residual Boundary

SFTP v3 does not provide an atomic compare-and-set permission operation. Snapshot validation prevents changes based on stale UI state, but another actor can still modify an entry between the final metadata check and `SETSTAT`. Manual testing against the user's actual SFTP servers remains necessary for server-specific permission policy.
