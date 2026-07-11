# Phase 3G Evidence: Security Evidence Bundle

Date: 2026-07-02

## Scope

- Added a machine-readable Windows security evidence bundle index.
- Added validation for evidence documents, release artifacts, validation
  scripts, package identity, package version, and required release gates.
- Added PowerShell and cross-platform shell validation coverage.
- Integrated the evidence bundle check into Windows static checks.

## Safety Notes

- Phase 3 evidence documents must not remain pending before release.
- The evidence bundle does not replace full manual security review; it prevents
  missing or stale release evidence from being overlooked.
- Signed external distribution still requires a real certificate and release
  endpoint beyond the current internal validation flow.

## Validation

- Local Windows-client toolchain gate: passed.
  - Cross-platform static checks passed.
  - Windows update channel metadata validation passed.
  - Windows release quality smoke checks passed.
  - Windows security evidence bundle validation passed.
  - Windows non-UI projects built successfully.
  - `OrbitTerm.Security.Tests`: 57 passed, 0 failed.
- Security evidence self-inclusion check: passed.
  - `PHASE-3G-EVIDENCE.md` was added to the evidence bundle after this
    document was completed.
  - Local toolchain validation was rerun and passed with the updated bundle.
- Remote Windows toolchain gate: passed.
  - Test execution stayed inside the authorized Windows validation root.
  - Windows static checks passed.
  - Windows security evidence bundle validation passed.
  - Windows non-UI projects built successfully.
  - `OrbitTerm.Security.Tests`: 57 passed, 0 failed.
- Sensitive literal scan: passed.
  - No real remote test address, real password, private key, or passphrase
    literal was found in Phase 3G metadata, scripts, or documentation changes.
- Build artifact cleanup: passed.
  - No local Windows client `bin` or `obj` directories remain after cleanup.
  - Windows client file count after cleanup: 145.
