# Phase 4S Evidence: Checked SFTP Download Core Contract

## Scope

Phase 4S adds the checked native download contract required before a Windows file picker and download button can be introduced. It does not yet expose download from the Windows UI.

## Safety Properties

- `orbit_sftp_download_checked_v1` accepts only an existing checked SFTP session, a validated absolute remote path, and a bounded absolute local path.
- The destination file is opened with create-new semantics, so an existing local file is never overwritten.
- The JSON response contains the checked SFTP session ID, remote path, verified security generation, and transferred byte count. It deliberately omits the local destination path.
- Transfer failures map to a stable redacted `sftp_download_failed` error; no fallback uses legacy SFTP connect or transfer entry points.

## Verification

- Rust format check: passed.
- Checked SFTP FFI tests: passed, 15 of 15.
- orbit-core library tests: passed, 277 passed and 2 OpenSSH-fixture tests skipped by design.
- Windows static gate: passed.
- Remote Windows orbit-core build: passed for x64 MSVC Debug and Release.
- Local full Windows build: not run because the current macOS environment does not expose a .NET SDK.

## Next Integration Boundary

The Windows client must obtain the local destination through an explicit user file picker, call the checked ABI through the native bridge, and surface the typed result without sending a local path into diagnostics or logs.
