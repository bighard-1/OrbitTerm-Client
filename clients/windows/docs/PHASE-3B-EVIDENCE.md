# Phase 3B Evidence: MSIX Package Identity Skeleton

Date: 2026-07-02

## Scope

- Added a Windows package manifest for `OrbitTerm.App`.
- Added explicit package project properties for manifest selection, signing
  policy, app-installer generation, bundle behavior, and package output
  location.
- Added package identity, display name, publisher placeholder, version, Windows
  Desktop target family, and minimum supported Windows platform floor.
- Limited package capabilities to internet client plus full-trust desktop
  execution.
- Extended the release candidate gate to validate package manifest content and
  required visual asset dimensions.
- Extended the release candidate gate to clean generated package publish
  directories before asserting no distributable-like leftovers remain.

## Safety Notes

- The package publisher is a development placeholder and must match the final
  commercial signing certificate before external distribution.
- Project-level package signing remains disabled until a real release signing
  certificate and packaging flow are introduced.
- Unsigned internal candidate mode remains non-distributable.

## Validation

- Local manifest and asset check: passed.
  - `Package.appxmanifest` parsed successfully.
  - `OrbitTerm.App.csproj` parsed successfully.
  - Required PNG assets were present with the expected dimensions:
    `StoreLogo.png` 50x50, `Square44x44Logo.png` 44x44,
    `Square71x71Logo.png` 71x71, `Square150x150Logo.png` 150x150,
    `Square310x310Logo.png` 310x310, `Wide310x150Logo.png` 310x150,
    and `SplashScreen.png` 620x300.
- Local Windows-client toolchain gate: passed.
  - Windows static checks passed.
  - Windows non-UI projects built successfully.
  - `OrbitTerm.Security.Tests`: 54 passed, 0 failed.
- Remote Windows release candidate gate: passed after self-review fix.
  - Initial self-check finding: WinUI Release build generated a `publish`
    directory under build output, and the gate correctly rejected the leftover.
  - Fix: the release candidate gate now removes generated `publish`
    directories under `bin` or `obj` before asserting no distributable-like
    leftovers remain.
  - Test execution stayed inside the authorized Windows validation root.
  - WinUI release project properties were pinned and validated.
  - MSIX package manifest and visual assets were pinned and validated.
  - Unsigned internal candidate mode was explicit and marked not approved for
    external distribution.
  - Existing Windows host validation ran in Release configuration.
  - Windows non-UI projects built successfully.
  - `OrbitTerm.Security.Tests`: 54 passed, 0 failed.
  - `orbit-core` built for Windows x64 MSVC Release.
  - `orbit_core.dll` loaded and exposed required checked terminal exports.
  - Full WinUI solution built on Windows x64 Release with 0 warnings and 0
    errors.
  - Release native bridge DLL existed after validation.
  - Generated package `publish` directories were cleaned after validation.
  - No TestResults, coverage, or publish directories were left in the source
    tree.
- Sensitive literal scan: passed.
  - No real remote test address or real password literal was found in Phase 3B
    script, manifest, project, or documentation changes.
  - Matches were limited to the signing certificate parameter name and the
    development publisher placeholder.
- Build artifact cleanup: passed.
  - No local Windows client `bin` or `obj` directories remain after cleanup.
  - Windows client file count after cleanup: 131.
