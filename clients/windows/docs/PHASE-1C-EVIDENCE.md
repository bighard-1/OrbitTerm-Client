# Phase 1C Evidence: Connection and Terminal First Screen

Date: 2026-06-30

## Scope

Phase 1C adds the first usable Windows client screen for the secure MVP. The
screen connects the existing checked SSH flow, Host Key trust action, terminal
channel opening, and terminal control commands into a restrained WinUI shell.
Business logic remains outside XAML code-behind in a separate Presentation
project.

## Implemented

- Replaced the placeholder main window with a three-column operational layout:
  assets and connection input, terminal surface, and security/session status.
- Added `OrbitTerm.Presentation` as a non-UI project for UI state and commands.
- Added `MainWindowViewModel`, command helpers, asset view models, and terminal
  line models.
- App launch now wires `CheckedOrbitCoreClient`, `WindowsCredentialVault`,
  `WindowsKnownHostsPathProvider`, `SessionOrchestrator`, and
  `MainWindowViewModel`.
- Password input is saved through `ICredentialVault` before starting the checked
  connection flow.
- Added Presentation tests for connection command eligibility and asset field
  synchronization.
- Added `OrbitTerm.Presentation` to the solution and Windows toolchain checks.

## Safety Properties

- XAML code-behind contains only view plumbing.
- UI state does not call raw native methods.
- Connection still flows through `SessionOrchestrator` and checked FFI types.
- Password material enters through `ICredentialVault`; it is not passed directly
  from UI to NativeBridge.
- Port input is parsed and range-checked before connection.

## Verification

- `clients/windows/scripts/check_windows_toolchain.sh`
  - Windows static scans: pass.
  - Non-UI project builds, including Presentation: pass, 0 warnings, 0 errors.
  - `OrbitTerm.Security.Tests`: 42 passed, 0 failed.
- `dotnet build clients/windows/src/OrbitTerm.App/OrbitTerm.App.csproj`
  - Dependencies restore and non-XAML projects build.
  - Fails on macOS at Windows App SDK `XamlCompiler.exe`, as expected.

## Known Limits

- Full WinUI/XAML compilation must be completed on a Windows x64 host.
- Real terminal output callback wiring is not part of this phase.
