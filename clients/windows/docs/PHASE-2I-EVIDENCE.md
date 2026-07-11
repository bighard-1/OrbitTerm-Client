# Phase 2I Evidence: Checked SFTP Text Preview

Date: 2026-07-02

## Scope

- Added checked SFTP text-read ABI and Host Key envelope payloads.
- Added Windows NativeBridge parsing for checked SFTP text preview responses.
- Added Application mapping from checked SFTP leases to read-only text preview
  results.
- Added Presentation and WinUI support for read-only SFTP text preview by path.
- Kept save, upload, download, edit, delete, rename, mkdir, chmod, and
  create-file actions unavailable.

## Safety Notes

- Windows uses only `orbit_sftp_read_text_checked_v1` for text preview.
- The legacy `orbit_sftp_read_text_file` ABI remains preserved for
  compatibility but is not called by the Windows client.
- Remote paths remain bounded absolute Unix paths without control characters,
  backslashes, or parent traversal.
- Text preview payloads are UTF-8 only and capped at 2 MiB before crossing into
  Windows.
- Error envelopes use stable redacted codes and do not include credentials,
  known_hosts paths, public keys, private keys, file paths from backend errors,
  or backend exception text.

## Validation

- Local Windows-client toolchain gate: passed.
  - Windows non-UI projects built successfully.
  - `OrbitTerm.Security.Tests`: 54 passed, 0 failed.
- Rust checked SFTP FFI tests: passed.
  - `checked_sftp_ffi`: 13 passed, 0 failed.
- Remote Windows host validation: passed.
  - Test execution stayed inside the authorized Windows test root.
  - Windows non-UI projects built successfully.
  - `OrbitTerm.Security.Tests`: 54 passed, 0 failed.
  - `orbit-core` built for Windows x64 MSVC.
  - `orbit_core.dll` loaded and exposed required checked terminal exports.
  - Full WinUI solution built on Windows x64 with 0 warnings and 0 errors.
- Full repository security gate: passed.
  - Rust debug tests: 275 passed, 0 failed, 2 ignored.
  - Rust release tests: 275 passed, 0 failed, 2 ignored.
  - Rust release legacy ABI guard: passed.
  - Rust clippy and build gates: passed.
  - Header and ABI symbol checks: passed.
  - Apple release gates: passed.
  - Final whitespace validation: passed.
- OpenSSH smoke: passed.
  - Trusted, changed, and revoked Host Key loopback scenarios passed.
  - Release legacy no-socket scenario passed.
- Sensitive literal scan: passed.
  - No real remote test address or real password literal was found in the
    Windows client, Windows evidence, architecture ADR, security script, or
    ignore rules.
  - Matches were limited to normal password field/control names and evidence
    text.
- Build artifact cleanup: passed.
  - No Windows client `bin` or `obj` directories remain.
  - Windows client file count after cleanup: 120.
