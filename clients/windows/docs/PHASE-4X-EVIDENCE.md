# Phase 4X Evidence: Windows SFTP Mutation Integration

## Scope

Phase 4X carries the checked SFTP directory-creation, rename, and removal contracts through the Windows native bridge, application orchestration layer, presentation model, and WinUI interaction surface.

## Interaction And Safety

- New-folder and rename operations accept one UTF-8 child name, reject separators, control characters, dot aliases, overlong names, and non-canonical resulting paths.
- Rename and removal use the size, full Unix mode, modified time, and directory type captured by the selected directory listing.
- Removal requires an explicit confirmation dialog whose default action is Cancel.
- The confirmed entry must still be selected and present in the current listing before removal is dispatched.
- Core snapshot validation reports stale entries and refuses overwrite of an existing rename target.
- Removal dispatches to file/link removal or empty-directory removal; recursive deletion is not exposed.
- Successful mutations refresh the parent directory before reporting completion.
- SFTP permission display now includes the file-type prefix so Windows directory classification and the raw snapshot describe the same entry.

## Review Findings Resolved

- Removed the unsupported WinUI `TextBox.SelectAllOnFocus` property found by the Windows application build.
- Corrected the SFTP permission display from a permission-only string to the standard type-prefixed form.
- Changed the PowerShell static gate to prune `bin` and `obj` while traversing instead of enumerating build outputs and filtering afterward.

## Verification

- Windows automated tests: 73 passed, 0 failed.
- Windows WinUI Release solution build: passed with 0 warnings and 0 errors.
- Checked SFTP Rust tests: 33 passed, 0 failed.
- Full Rust core tests: 284 passed, 0 failed, 2 environment fixtures ignored.
- Rust Clippy with warnings denied: passed.
- Local Windows static gate: passed.
- Remote Windows static gate: passed with the final mutation markers and traversal fix.
- Diff whitespace check: passed.
- Remote Windows x64 MSVC Debug build: passed.
- Remote Windows x64 MSVC Release build: passed and produced `orbit_core.dll`.
- Remote validation was confined to `D:\\Macmini2\\phase-4x-validate`.

## Residual Boundary

SFTP v3 does not provide an atomic compare-and-mutate primitive. The checked snapshot prevents operations based on stale UI state, but another actor can still modify an entry between the final metadata check and the server mutation. Manual desktop testing against the user's actual SSH servers remains necessary for server-specific permissions and rename semantics.
