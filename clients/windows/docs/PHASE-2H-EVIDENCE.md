# Phase 2H Evidence: Checked SFTP Directory Listing

Date: 2026-07-02

## Scope

- Added checked SFTP directory list ABI and Host Key envelope payloads.
- Added Windows NativeBridge parsing for checked SFTP directory list responses.
- Added Application mapping from checked SFTP leases to read-only directory
  list results.
- Upgraded the SFTP browser from path preparation to real read-only listing.
- Kept upload, download, edit, delete, rename, mkdir, chmod, and create-file
  actions unavailable.

## Safety Notes

- Windows uses only `orbit_sftp_list_checked_v1` for directory listing.
- The legacy `orbit_sftp_list_dir` ABI remains preserved for compatibility but
  is not called by the Windows client.
- Remote paths remain bounded absolute Unix paths without control characters,
  backslashes, or parent traversal.
- Directory entries are bounded before crossing into Windows and contain only
  display metadata.
- Error envelopes use stable redacted codes and do not include credentials,
  known_hosts paths, public keys, private keys, or backend exception text.

## Validation

- Local Windows-client toolchain gate: passed.
  - Windows non-UI projects built successfully.
  - `OrbitTerm.Security.Tests`: 54 passed, 0 failed.
- Rust checked SFTP FFI tests: passed.
  - `checked_sftp_ffi`: 10 passed, 0 failed.
- Remote Windows host validation: passed.
  - Test paths were restricted to the authorized Windows test root.
  - Windows non-UI projects built successfully.
  - `OrbitTerm.Security.Tests`: 54 passed, 0 failed.
  - `orbit-core` built for Windows x64 MSVC.
  - `orbit_core.dll` loaded and exposed required checked terminal exports.
  - Full WinUI solution built on Windows x64 with 0 warnings and 0 errors.
- Full repository security gate: passed.
  - Rust debug tests: 272 passed, 0 failed, 2 ignored.
  - Rust release tests: 272 passed, 0 failed, 2 ignored.
  - Rust release legacy ABI guard: passed.
  - Rust clippy and builds: passed.
  - Header and ABI symbol checks: passed.
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
  - Windows client file count after cleanup: 118.
