# Phase 4T Evidence: Checked SFTP Download UI Integration

## Scope

Phase 4T connects the checked SFTP download ABI to the Windows client without exposing legacy transfer APIs.

## Safety Properties

- The user chooses the local destination folder through the Windows folder picker.
- Only a selected non-directory SFTP entry can be downloaded.
- Both the native bridge and core require a new, fully qualified local path; existing files are not overwritten.
- The local destination path is not placed in download results, diagnostics, or operation status.

## Verification

- Local static gate: passed.
- Local diff whitespace check: passed.
- Remote Windows static gate: passed.
- Remote Windows non-UI project builds: passed with 0 warnings and 0 errors.
- Remote Windows security tests: passed, 71 of 71 tests.
- Remote Windows WinUI solution build: passed with 0 warnings and 0 errors.
- The save-file picker interaction was compile-verified on Windows. It was not manually exercised because the available remote session is SSH-only and cannot present the desktop picker.
