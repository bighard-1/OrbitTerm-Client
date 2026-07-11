# Phase 3A Evidence: Release Candidate Gate

Date: 2026-07-02

## Scope

- Added a Windows-only release candidate validation gate.
- Kept commercial distribution honest by requiring a signing certificate
  thumbprint unless explicitly running an unsigned internal candidate check.
- Reused the existing Windows host validation harness in Release mode instead
  of duplicating build logic.
- Added release project property checks for WinUI, Windows App SDK packaging
  tooling, x64, and the supported Windows platform floor.
- Added cleanup-sensitive checks for TestResults, coverage, and publish
  leftovers inside the Windows client source tree.

## Safety Notes

- Unsigned internal candidate mode is not a distributable release approval.
- The script refuses to run outside the authorized Windows validation root.
- Release validation continues to depend on the checked native bridge and the
  existing Windows host build/load gates.

## Validation

- Local Windows-client toolchain gate: passed.
  - Windows static checks passed, including required script inventory.
  - Windows non-UI projects built successfully.
  - `OrbitTerm.Security.Tests`: 54 passed, 0 failed.
- Remote Windows release candidate gate: passed.
  - Test execution stayed inside the authorized Windows validation root.
  - WinUI release project properties were pinned and validated.
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
  - No TestResults, coverage, or publish directories were left in the source
    tree.
- Sensitive literal scan: passed.
  - No real remote test address or real password literal was found in Phase 3A
    script or documentation changes.
  - Matches were limited to the signing certificate parameter name.
- Build artifact cleanup: passed.
  - No local Windows client `bin` or `obj` directories remain after cleanup.
