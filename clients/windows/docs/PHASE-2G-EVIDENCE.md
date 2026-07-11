# Phase 2G Evidence: SFTP Browser Safety Shell

Date: 2026-07-01

## Scope

- Added a Windows SFTP browser preparation area that becomes actionable only
  after a checked SFTP channel is open.
- Added Presentation-owned remote path normalization and rejection rules.
- Kept directory listing, transfer, edit, and delete operations disabled until
  checked SFTP APIs are available through the Windows bridge.
- Added tests for command gating, path normalization, dangerous path rejection,
  and session cleanup.

## Safety Notes

- The Windows client still uses only the checked SFTP channel entry point.
- Legacy SFTP file-operation ABI functions are not called by the Windows
  client in this phase.
- UI copy is explicit that listing and file operations are pending checked
  SFTP APIs.
- Remote paths are bounded to 512 characters and must remain absolute Unix
  paths without parent traversal.

## Validation

- Local Windows-client toolchain gate: passed.
  - Windows non-UI projects built successfully.
  - `OrbitTerm.Security.Tests`: 53 passed, 0 failed.
- Remote Windows host validation: passed.
  - Test paths were restricted to the authorized Windows test root.
  - Windows non-UI projects built successfully.
  - `OrbitTerm.Security.Tests`: 53 passed, 0 failed.
  - `orbit-core` built for Windows x64 MSVC.
  - `orbit_core.dll` loaded and exposed required checked terminal exports.
  - Full WinUI solution built on Windows x64 with 0 warnings and 0 errors.
- Full repository security gate: passed.
  - Rust debug tests: 268 passed, 0 failed, 2 ignored.
  - Rust release legacy ABI guard: passed.
  - Apple release gates: passed.
  - Final whitespace validation: passed.
- OpenSSH smoke: passed.
  - Trusted Host Key loopback scenario passed.
  - Changed Host Key loopback scenario passed.
  - Revoked Host Key loopback scenario passed.
  - Release legacy no-socket scenario passed.
- Sensitive literal scan: passed.
  - No real remote test address or real password literal was found in the
    Windows client, Windows architecture ADR, security gate script, or
    `.gitignore`.
  - Matches were limited to normal password field/control names and evidence
    text.
- Build artifact cleanup: passed.
  - No Windows client `bin` or `obj` directories remain after cleanup.
