# Phase 0D Evidence: Verified Session and Terminal Channel Lifecycle

Date: 2026-06-30

## Scope

Phase 0D adds the first application-owned lifecycle boundary for Windows SSH
sessions. The UI should not pass raw native identifiers around or open terminal
channels from unverified state. A successful checked SSH connection now registers
a `VerifiedSessionLease`; opening a terminal goes through the application layer,
which validates the lease, PTY size, base session identity, and HostKeyVerified
channel payload.

## Implemented

- Added `ICheckedOrbitCoreClient` so application orchestration depends on a
  checked contract rather than a concrete P/Invoke wrapper.
- Added `CheckedTerminalOpenOutcome` for strong terminal-open decoding.
- Added `VerifiedSessionRegistry` to store the current verified lease per
  workspace/server pair.
- Added `TerminalOpenResult` and `TerminalSessionLease` for UI-safe terminal
  channel state.
- Updated `SessionOrchestrator` to register verified connection leases and to
  open terminal channels only from registered verified sessions.

## Safety Properties

- Terminal opening cannot proceed without a registered verified SSH session.
- Terminal channel payloads must remain bound to the requested base session.
- PTY dimensions are validated before and after the native call.
- Native terminal errors remain structured as code/message-key pairs.
- UI-facing application models do not expose raw P/Invoke entry points.

## Verification

- `clients/windows/scripts/check_windows_toolchain.sh`
  - Windows static scans: pass.
  - Non-UI project builds: pass, 0 warnings, 0 errors.
  - `OrbitTerm.Security.Tests`: 24 passed, 0 failed.

## Known Limits

- Full WinUI/XAML compilation still requires a Windows x64 host.
- The real Windows `orbit_core.dll` smoke remains a Windows-host validation item.
