# Phase 0B Evidence

## Scope

Phase 0B brings up the Windows client toolchain far enough for repeatable
cross-platform checks and prepares the remaining Windows-only verification
steps.

## Completed

- Installed and used .NET SDK 9.0.315 on the local macOS environment.
- Added `EnableWindowsTargeting` for non-Windows build hosts.
- Limited unsafe code to `OrbitTerm.NativeBridge`, where `LibraryImport`
  requires it.
- Added central NuGet package version management.
- Enabled NuGet lock files.
- Added `check_windows_toolchain.sh` and `check_windows_toolchain.ps1`.
- Added Windows-only `build_windows_core.ps1` for `orbit_core.dll`.
- Added `OrbitNativeLibraryLoader` so Windows can load `orbit_core.dll` from
  app-local native paths.

## Verification Results

Executed locally:

```bash
DOTNET=/Users/cwz/.dotnet/dotnet clients/windows/scripts/check_windows_toolchain.sh
```

Result:

- Windows static checks: passed.
- `OrbitTerm.NativeBridge`: build passed, 0 warnings, 0 errors.
- `OrbitTerm.Terminal`: build passed, 0 warnings, 0 errors.
- `OrbitTerm.Application`: build passed, 0 warnings, 0 errors.
- `OrbitTerm.Platform.Windows`: build passed, 0 warnings, 0 errors.
- `OrbitTerm.Security.Tests`: 4 passed, 0 failed.

## Review Findings and Fixes

- Finding: building Windows-targeted projects on macOS failed with
  `NETSDK1100`.
- Fix: `Directory.Build.props` now sets `EnableWindowsTargeting` when the host
  OS is not Windows.

- Finding: `LibraryImport` generated unsafe code, but unsafe compilation was
  not enabled.
- Fix: `AllowUnsafeBlocks` is enabled only for `OrbitTerm.NativeBridge`.

- Finding: full solution build reaches the WinUI App project but fails on
  Darwin because Windows App SDK invokes `XamlCompiler.exe`.
- Fix: toolchain checks now build all non-UI projects cross-platform and make
  the full WinUI build a Windows-only check.

## Windows-Only Remaining Checks

These require a Windows x64 development machine or CI runner:

```powershell
pwsh clients/windows/scripts/check_windows_toolchain.ps1
pwsh clients/windows/scripts/build_windows_core.ps1
```

Expected outcomes:

- Full WinUI solution builds.
- `orbit-core` produces `orbit_core.dll` for `x86_64-pc-windows-msvc`.
- App-local native loading can find `orbit_core.dll`.

## Progress

Overall Windows client progress: 9%.
