# Phase 0E Evidence: Terminal Control Boundary

Date: 2026-06-30

## Scope

Phase 0E adds the controlled runtime operations for an already-open terminal:
write, resize, and close. The existing Rust ABI for these operations returns a
compact terminal-control response, so Windows keeps that parsing inside
`OrbitTerm.NativeBridge` and exposes only application-owned outcomes above it.

## Implemented

- Added `TerminalControlResult` in NativeBridge to decode terminal control
  responses behind the native boundary.
- Added P/Invoke wrappers for terminal write, resize, and close.
- Added `TerminalSessionRegistry` to track active terminal leases.
- Added `TerminalControlOutcome` for UI-safe success/failure states.
- Updated `SessionOrchestrator` so terminal write, resize, and close require the
  current active terminal lease.
- Resize updates the active terminal lease size only after a successful native
  result.
- Close removes the active terminal lease only after a successful native result.

## Safety Properties

- UI and application code do not parse native terminal control strings.
- Terminal operations cannot run against an unknown or stale terminal lease.
- Terminal writes are bounded to 64 KiB per call.
- Terminal resize is validated before native invocation.
- Backend error details are converted to stable UI-safe keys.
- Raw `NativeMethods` remains isolated to `OrbitTerm.NativeBridge`.

## Verification

- `clients/windows/scripts/check_windows_toolchain.sh`
  - Windows static scans: pass.
  - Non-UI project builds: pass, 0 warnings, 0 errors.
  - `OrbitTerm.Security.Tests`: 33 passed, 0 failed.

## Known Limits

- Full WinUI/XAML compilation still requires a Windows x64 host.
- Real Windows terminal IO still needs a Windows-host smoke once
  `orbit_core.dll` is built for MSVC.
