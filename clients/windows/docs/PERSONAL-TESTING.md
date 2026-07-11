# Windows Personal Testing

This guide is for personal testing on a Windows development machine. It is not a commercial distribution or a release procedure.

## Requirements

- Windows 10 version 19041 or later.
- A supported .NET SDK available through `dotnet`.
- A local checkout of this repository. The test checkout may live under `D:\Macmini2\OrbitTerm-Client`.

Do not place SSH passwords, private keys, or host credentials in the repository, scripts, or diagnostics copied from the app.

## Preflight

From the repository root, run the full Windows validation gate:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\clients\windows\scripts\check_windows_toolchain.ps1 -Root .\clients\windows
```

## Build Validation Without Opening the App

Use the personal launcher with `-NoLaunch` to run its static preflight and build the Debug x64 executable without opening a window:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\clients\windows\scripts\run_windows_personal_test.ps1 -Root .\clients\windows -NoLaunch
```

## Launch for Personal Testing

Run the same launcher without `-NoLaunch`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\clients\windows\scripts\run_windows_personal_test.ps1 -Root .\clients\windows
```

The launcher executes `check_windows_static.ps1` before it builds and opens the application. `-SkipStaticGate` is reserved for investigating a broken validation environment; it is not part of normal personal testing.

The Debug executable is created below `clients\windows\src\OrbitTerm.App\bin\x64\Debug`. Build artifacts are local and may be cleaned with the IDE's Clean command when they are no longer needed.
