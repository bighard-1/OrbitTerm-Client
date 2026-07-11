# Phase 4W Evidence: Checked SFTP Mutation Core

## Scope

Phase 4W adds checked native-core contracts for creating directories, renaming entries, and removing files, links, or empty directories. Windows UI integration is intentionally deferred until these contracts are stable.

## Safety Boundary

- Every operation requires an existing checked SFTP session bound to a Host Key verified base session.
- Mutation paths must be bounded, absolute, and canonical. Root, root aliases, parent traversal, duplicate separators, dot segments, and trailing separators are rejected.
- Directory creation is single-level and refuses an existing target. It does not run a remote shell command or create missing parents.
- Rename revalidates the selected source size, permissions, modified time, and directory type before checking that the destination does not exist.
- Remove revalidates the same selected-entry snapshot and dispatches explicitly to file/link removal or empty-directory removal.
- Stable error codes distinguish an unavailable session, existing target, changed entry, invalid request, and backend failure without exposing remote paths or backend messages.

## Concurrency Limit

SFTP v3 cannot atomically combine metadata comparison with rename or removal. Snapshot validation protects against stale UI state, but an external actor can still change an entry after validation and before the mutation request reaches the server. The Windows confirmation UX must describe this boundary honestly.

## Verification

- Checked SFTP tests: 33 passed, 0 failed.
- Host Key FFI protocol tests: 24 passed, 0 failed.
- Full Rust core tests: 284 passed, 0 failed, 2 environment fixtures ignored.
- Rust formatting check: passed.
- Rust Clippy with warnings denied: passed.
- Local Release core build: passed.
- Windows static gate: passed.
- Diff whitespace check: passed.
- Remote Windows x64 MSVC Debug build: passed.
- Remote Windows x64 MSVC Release build: passed and produced `orbit_core.dll`.
- Remote validation was confined to `D:\Macmini2\phase-4w-validate`.
