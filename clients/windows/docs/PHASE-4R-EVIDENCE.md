# Phase 4R Evidence: Read-Only SFTP Interaction Completion

## Scope

Phase 4R improves the personal-use SFTP browsing workflow without enabling unchecked transfer, edit, rename, or delete operations.

## Implementation

- Pressing Enter in the SFTP path field lists the normalized path.
- Double-clicking a selected SFTP directory entry opens a directory or previews a file through the existing checked SFTP path.
- A successful text preview can be copied explicitly from the SFTP panel or menu.
- Preview copy availability follows the actual preview content and does not expose a write operation.

## Safety Review

- The feature uses the existing checked directory-list and text-preview APIs only.
- No SFTP write ABI, shell fallback, or legacy native entry point is introduced.
- Copying happens only after a user action and only for content already rendered in the read-only preview.

## Verification

- Local static gate: passed.
- Local diff whitespace check: passed.
- Local full .NET build: not run because the current macOS environment does not expose a `dotnet` SDK.
- Remote Windows static gate: passed, including the SFTP browse interaction contract.
- Remote Windows non-UI project builds: passed with 0 warnings and 0 errors.
- Remote Windows security tests: passed, 71 of 71 tests.
- Remote Windows WinUI solution build: passed with 0 warnings and 0 errors.
- Remote personal launcher: `run_windows_personal_test.ps1 -NoLaunch` passed after its default static gate and resolved `OrbitTerm.App.exe`.
- The remote verification copy was restored from its baseline archive after a broad cleanup selector removed its generated and source subdirectories. The affected directory was the isolated `phase-4q-validate` copy only; the existing project directory and other `D:\\Macmini2` content were not touched. Subsequent work retained build outputs rather than repeating that selector.
