# Phase 4P Evidence: Personal Windows Test Launcher

Date: 2026-07-09

## Scope

- Added a Windows-only personal test launcher for local app testing.
- Kept the launcher inside the Windows client script boundary.
- Added static checks so the launcher remains present and retains its core
  safety contract.
- Did not change SSH, SFTP, terminal, monitor, Docker, or credential runtime
  behavior.

## Implementation Evidence

- `run_windows_personal_test.ps1` builds `OrbitTerm.App` with the requested
  configuration and x64 platform.
- The launcher refuses to run on non-Windows hosts.
- The launcher resolves the generated `OrbitTerm.App.exe` under the app output
  tree instead of assuming a hard-coded framework folder.
- The launcher supports `-NoLaunch` so validation can build and inspect the app
  without opening the UI.
- PowerShell and shell static checks now require the launcher and verify its
  key behavior markers.

## Self-Review

- The script writes only through the normal .NET build output tree.
- The script does not create files in system directories.
- The script does not embed remote host, username, password, token, or local
  machine-specific paths.
- The script does not bypass existing release/signing/package checks.

## Verification

- Local Windows static gate: passed.
- Local Windows toolchain gate: blocked because the current macOS execution
  environment does not expose a dotnet SDK.
- Remote Windows static gate: passed.
- Remote Windows security tests: passed, 71 total, 0 failed.
- Remote Windows non-UI builds: passed with 0 warnings and 0 errors.
- Remote Windows full WinUI build: passed with 0 warnings and 0 errors.
- Remote personal test launcher with `-NoLaunch`: passed with 0 warnings and
  0 errors, and resolved `OrbitTerm.App.exe`.

## Result

Phase 4P passed local static validation and remote Windows validation.
