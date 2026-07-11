# Phase 2F Evidence: SFTP Channel Entry

## Scope

Phase 2F starts Windows SFTP parity by exposing a checked SFTP channel open
workflow. This phase intentionally stops at channel entry and state reporting;
directory listing, transfer, and mutation operations remain future phases.

## Implementation Notes

- `SftpChannelOpenedPayload` now validates and parses numeric base/SFTP ids.
- `SessionOrchestrator.OpenSftpAsync` requires an active verified session.
- `SftpOpenResult` maps checked SFTP envelopes into UI-safe application
  results.
- `MainWindowViewModel` owns SFTP state and exposes `OpenSftpCommand`.
- End Session clears SFTP state together with terminal and verified session
  state.
- WinUI exposes Open SFTP through command binding only.

## Validation

Completed validation for this phase:

- Local Windows client toolchain check passed.
- Local Windows security tests passed: 52 passed, 0 failed.
- Windows host validation stayed under the approved Windows test root.
- Windows host security tests passed: 52 passed, 0 failed.
- `orbit-core` Windows x64 MSVC build passed.
- `orbit_core.dll` dynamic load and checked terminal export smoke passed.
- Full WinUI solution build passed on Windows x64.
- Full repository security gate passed.
- OpenSSH release-candidate smoke passed.
- Sensitive information scan found no remote host address or credentials; only
  normal password field/control names and evidence text were matched.
- Build artifact cleanup check passed; no Windows `bin` or `obj` directories
  remained after cleanup.

## Review Notes

- No raw native method calls were added to UI code.
- No file operation UI is exposed before list/transfer policies are designed.
- NativeBridge continues to use checked SFTP FFI only.
