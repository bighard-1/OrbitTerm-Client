# Phase 3C Evidence: Signed Package Build Contract

Date: 2026-07-02

## Scope

- Added a dedicated signed package build script.
- Added certificate-bound package creation requirements.
- Added authorized-root checks for source and package output directories.
- Added plan-only validation for environments without a commercial signing
  certificate.
- Reused the release candidate gate before signed package generation.
- Added the signed package script to static script inventory.

## Safety Notes

- Plan-only mode never produces a distributable package.
- Real package creation requires a signing certificate thumbprint.
- The certificate must be present in the Windows certificate store, unexpired,
  include a private key, and match the package manifest publisher.
- Package output is restricted to the authorized Windows release root.

## Validation

- Local Windows-client toolchain gate: passed.
  - Windows static checks passed, including signed package script inventory.
  - Windows non-UI projects built successfully.
  - `OrbitTerm.Security.Tests`: 54 passed, 0 failed.
- Remote Windows signed package plan validation: passed.
  - Test execution stayed inside the authorized Windows validation root.
  - Signed package output root was restricted to the authorized Windows release
    root.
  - Plan-only mode accepted the workflow without a signing certificate
    thumbprint but refused unsigned package output.
  - No `.msix`, `.appx`, `.msixbundle`, or `.appxbundle` file was produced in
    the plan-only output directory.
- Sensitive literal scan: passed.
  - No real remote test address or real password literal was found in Phase 3C
    script or documentation changes.
  - Matches were limited to signing certificate parameter names.
- Build artifact cleanup: passed.
  - No local Windows client `bin` or `obj` directories remain after cleanup.
  - Windows client file count after cleanup: 133.
