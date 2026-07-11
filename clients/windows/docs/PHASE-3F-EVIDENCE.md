# Phase 3F Evidence: Release Quality Smoke Gate

Date: 2026-07-02

## Scope

- Added release quality metadata for minimum window size, minimum text size,
  keyboard access, accessible names, high-DPI safety, and localization.
- Added release quality smoke validation scripts for PowerShell and
  cross-platform shell gates.
- Added minimum window dimensions to the main window.
- Added accessible names for icon-only history controls, key lists, and SFTP
  preview text.

## Safety Notes

- This phase provides automated smoke checks, not a substitute for a full
  manual accessibility audit.
- External distribution still requires reviewed string resources beyond the
  current default `en-US` metadata.
- High-DPI smoke checks currently reject unmanaged raster `Image` elements in
  XAML until reviewed variants exist.

## Validation

- Local Windows-client toolchain gate: passed.
  - Cross-platform static checks passed.
  - Windows update channel metadata validation passed.
  - Windows release quality smoke checks passed.
  - Windows non-UI projects built successfully.
  - `OrbitTerm.Security.Tests`: 57 passed, 0 failed.
- Remote Windows toolchain gate: passed.
  - Test execution stayed inside the authorized Windows validation root.
  - Windows static checks passed.
  - Windows release quality smoke checks passed.
  - Windows non-UI projects built successfully.
  - `OrbitTerm.Security.Tests`: 57 passed, 0 failed.
- Sensitive literal scan: passed.
  - No real remote test address, real password, private key, or passphrase
    literal was found in Phase 3F metadata, scripts, XAML, or documentation
    changes.
- Build artifact cleanup: passed.
  - No local Windows client `bin` or `obj` directories remain after cleanup.
  - Windows client file count after cleanup: 142.
