# Phase 1A Evidence: Host Key Trust Persistence

Date: 2026-06-30

## Scope

Phase 1A completes the unknown Host Key trust confirmation path at the Windows
application boundary. The UI can now receive a trustable challenge, carry the
checked request identifier, and ask the application layer to persist that
challenge into the Windows known_hosts path. The implementation deliberately
does not introduce an accept-anyway or replacement flow.

## Implemented

- Added `HostKeyTrustPersistedPayload` and `CheckedHostKeyTrustOutcome` in
  NativeBridge.
- Added `AcceptAndPersistHostKey` to `ICheckedOrbitCoreClient` and
  `CheckedOrbitCoreClient`.
- Extended `HostKeyChallengeViewModel` with the checked request identifier.
- Added `HostKeyTrustResult` for UI-safe persisted/failed results.
- Added `SessionOrchestrator.TrustHostKeyAsync`.
- Added matching checks between the active challenge and persisted response.
- Added bounded comment cleanup before crossing the native boundary.

## Safety Properties

- A challenge missing a request identifier is rejected before it can become a
  trust prompt.
- Persisted results must match challenge id, normalized host, port, key
  algorithm, and SHA256 fingerprint.
- Changed/replacement Host Key states remain blocked by the existing challenge
  mapping.
- Persistence errors remain structured and do not expose local paths.
- UI-facing code does not parse Host Key protocol JSON.

## Verification

- `clients/windows/scripts/check_windows_toolchain.sh`
  - Windows static scans: pass.
  - Non-UI project builds: pass, 0 warnings, 0 errors.
  - `OrbitTerm.Security.Tests`: 38 passed, 0 failed.

## Known Limits

- Full WinUI/XAML compilation still requires a Windows x64 host.
- End-to-end Windows trust persistence against a real `orbit_core.dll` remains
  a Windows-host smoke item.
