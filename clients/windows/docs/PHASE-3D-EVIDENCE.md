# Phase 3D Evidence: Update Channel Definition

Date: 2026-07-02

## Scope

- Added stable Windows update channel metadata.
- Added validation for package identity, publisher, version, minimum Windows
  version, transport, signing requirement, and rollout state.
- Kept external distribution disabled until production HTTPS update endpoints
  are configured.
- Included update channel validation in Windows static checks.

## Safety Notes

- No external update URI is enabled in this phase.
- Update metadata requires signed packages.
- Update metadata requires HTTPS transport before external distribution can be
  enabled.
- Disabled distribution must keep rollout at manual 0 percent.

## Validation

- Local Windows-client toolchain gate: passed.
  - Cross-platform static checks passed, including update channel metadata
    validation.
  - Windows non-UI projects built successfully.
  - `OrbitTerm.Security.Tests`: 54 passed, 0 failed.
- Remote Windows static and plan validation: passed.
  - Test execution stayed inside the authorized Windows validation root.
  - Windows static checks passed.
  - Windows update channel metadata validation passed.
  - Signed package plan-only validation passed.
  - Plan-only mode refused unsigned package output.
  - No `.msix`, `.appx`, `.msixbundle`, or `.appxbundle` file was produced in
    the plan-only output directory.
- Sensitive literal scan: passed.
  - No real remote test address or real password literal was found in Phase 3D
    metadata, scripts, or documentation changes.
  - Matches were limited to the development publisher placeholder, empty update
    URI fields, and HTTPS validation logic.
- Build artifact cleanup: passed.
  - No local Windows client `bin` or `obj` directories remain after cleanup.
  - Windows client file count after cleanup: 136.
