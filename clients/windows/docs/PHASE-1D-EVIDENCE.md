# Phase 1D Evidence: Terminal Output Callback Pipeline

Date: 2026-06-30

## Scope

Phase 1D connects terminal output callbacks to the Windows client. The design
keeps unmanaged pointers isolated in NativeBridge, validates active terminal
leases in Application, and updates Presentation through a dispatcher-safe event
path.

## Implemented

- Added `TerminalDataReceivedEventArgs` in NativeBridge.
- Added `TerminalOutputRouter` to register `orbit_terminal_set_callback` once.
- Added bounded copying from unmanaged callback bytes to managed byte arrays.
- Added `TerminalOutputReceivedEventArgs` in Application.
- `SessionOrchestrator` now subscribes to terminal output, verifies active
  terminal channel leases, updates `TerminalBacklog`, and publishes safe output
  events.
- `MainWindowViewModel` subscribes to application terminal output and dispatches
  collection changes through an injected UI dispatcher.
- Added tests for active terminal output delivery and closed/unknown channel
  rejection.

## Safety Properties

- UI and Presentation never receive unmanaged pointers.
- Output from unknown or closed terminal channels is ignored.
- Native callback byte payloads are capped at 1 MiB per callback.
- Backlog mutation is synchronized.
- Presentation collection updates are dispatched to the window thread.

## Verification

- `clients/windows/scripts/check_windows_toolchain.sh`
  - Windows static scans: pass.
  - Non-UI project builds, including Presentation: pass, 0 warnings, 0 errors.
  - `OrbitTerm.Security.Tests`: 44 passed, 0 failed.
- `dotnet build clients/windows/src/OrbitTerm.App/OrbitTerm.App.csproj`
  - Dependencies restore and non-XAML projects build.
  - Fails on macOS at Windows App SDK `XamlCompiler.exe`, as expected.

## Known Limits

- Full WinUI/XAML compilation must be completed on a Windows x64 host.
- Real callback rendering still needs a Windows-host smoke with `orbit_core.dll`.
