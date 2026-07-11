# Phase 1E Evidence: Windows Host Validation Harness

## Scope

This phase adds a Windows-only validation harness for real-machine checks that
cannot be completed on macOS:

- full WinUI XAML compilation on Windows x64;
- Rust `orbit-core` build for `x86_64-pc-windows-msvc`;
- `orbit_core.dll` dynamic load smoke;
- required checked terminal export verification.
- optional Windows dependency bootstrap for Rust MSVC and Visual Studio C++
  Build Tools.

## Safety Boundary

`scripts/check_windows_host.ps1` refuses to run unless the Windows client root
and repository root both resolve under the configured validation prefix. The
default prefix is:

```powershell
D:\Macmini2
```

This keeps host validation scoped to the dedicated test directory and prevents
accidental writes to unrelated Windows files.

## Validation Command

From a Windows x64 host where the repository lives under `D:\Macmini2`:

```powershell
powershell -ExecutionPolicy Bypass -File .\clients\windows\scripts\check_windows_host.ps1 `
  -Root .\clients\windows `
  -RepoRoot .
```

The script performs the following gates:

1. Confirms it is running on Windows x64.
2. Confirms `Root` and `RepoRoot` are under `D:\Macmini2`.
3. Runs the existing Windows toolchain checks.
4. Builds `orbit-core` with the MSVC target.
5. Loads the produced `orbit_core.dll`.
6. Verifies required checked terminal exports exist.
7. Restores and builds the full WinUI solution.

If a Windows host is missing Rust or Visual Studio C++ Build Tools, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\clients\windows\scripts\install_windows_dependencies.ps1
```

This installs system-level developer dependencies through winget and affects
standard Windows program and package-manager locations outside the repository.

## Validation Result

The harness was executed on a Windows x64 host with the repository extracted to
`D:\Macmini2\OrbitTerm-Client`.

Passed gates:

- validation paths restricted to `D:\Macmini2`;
- Windows static checks;
- Windows non-UI project build;
- Windows security tests: 44 passed, 0 failed;
- `orbit-core` debug and release builds for `x86_64-pc-windows-msvc`;
- `orbit_core.dll` dynamic load;
- required checked terminal exports present;
- full `OrbitTerm.Windows.sln` WinUI x64 build.

The same Windows toolchain gate was also run locally from macOS. It passed the
portable static, non-UI build, and managed security-test gates, while correctly
skipping the Windows-only WinUI build on Darwin.

## Self-Review

- No production UI code calls raw native methods.
- The host validation script is Windows-only and fails closed off Windows.
- The script checks path boundaries before running build commands and rejects
  sibling paths that only share a textual prefix.
- Windows host detection is compatible with Windows PowerShell 5 and PowerShell
  7+ instead of depending on newer shell-only variables.
- Native process exit codes are treated as hard validation failures, so build
  errors cannot be followed by a false PASS line.
- DLL load smoke uses Windows `LoadLibraryW`/`GetProcAddress`, which works on
  Windows PowerShell 5 and PowerShell 7+.
- The DLL smoke checks actual dynamic loading and required native exports
  without initiating SSH sessions or touching user credentials.
