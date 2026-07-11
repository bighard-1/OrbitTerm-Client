# Phase 0C Evidence

## Scope

Phase 0C strengthens the Windows checked FFI contract before building real UI
flows. The purpose is to ensure Host Key and checked-channel states are modeled
explicitly and cannot be accidentally treated as successful connections.

## Completed

- Added checked FFI kind constants.
- Added checked security generation decoding with an explicit JSON converter.
- Added typed Host Key payloads:
  - connected
  - unknown Host Key challenge
  - Host Key blocked
  - trust persisted
- Added typed channel payloads for Terminal and SFTP channel-open responses.
- Added checked connection outcome model.
- Added application-level connection result model.
- Updated `SessionOrchestrator` to return application-owned `ConnectResult`
  instead of raw native bridge outcome.
- Added tests for connected, challenge, blocked, error, terminal channel, SFTP
  channel, and application mapping invariants.

## Review Findings and Fixes

- Finding: the initial enum converter used a .NET API that is not available in
  the installed SDK.
- Fix: replaced it with a dedicated converter that accepts only
  `host_key_verified` and `legacy_unverified`, and rejects unknown values.

- Finding: raw NativeBridge outcomes would have leaked too much protocol detail
  into UI-facing layers.
- Fix: added `ConnectResult` in the application layer, so future UI code sees
  `Connected`, `RequiresHostKeyTrust`, `Blocked`, or `Failed`.

## Verification Results

Executed locally:

```bash
DOTNET=/Users/cwz/.dotnet/dotnet clients/windows/scripts/check_windows_toolchain.sh
```

Result:

- Windows static checks: passed.
- Non-UI Windows projects: build passed, 0 warnings, 0 errors.
- `OrbitTerm.Security.Tests`: 15 passed, 0 failed.

## Security Notes

- Changed or revoked Host Keys map to `ConnectResult.Blocked`.
- Replaceable Host Key challenge payloads are rejected by the application layer.
- Terminal and SFTP channels reject `LegacyUnverified` generations.
- UI still cannot call raw native methods directly.

## Remaining Before Phase 1

- Run Windows-only full WinUI build on Windows x64.
- Build `orbit_core.dll` on Windows x64.
- Add a real Windows credential vault implementation.
- Add a Host Key trust dialog view model and UI.

## Progress

Overall Windows client progress: 12%.
