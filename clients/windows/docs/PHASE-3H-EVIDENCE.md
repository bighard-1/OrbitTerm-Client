# Phase 3H Evidence: Final Internal Release Readiness Gate

Goal: make release readiness explicit and machine-checkable without confusing an
internal release candidate with an externally distributable commercial build.

## Implementation

- Added `release/release-readiness.json` as the single source of truth for the
  Windows internal release candidate profile.
- Added `scripts/check_windows_release_readiness.ps1` to validate package
  identity, version, update channel state, security evidence state, and release
  gate coverage.
- Added cross-platform release-readiness validation to
  `scripts/check_windows_static.sh`.
- Wired the PowerShell readiness gate into `scripts/check_windows_static.ps1`.
- Added the readiness metadata and validation script to the security evidence
  bundle.

## Validation

- Local cross-platform Windows toolchain gate: Passed.
- Remote Windows host toolchain gate: Passed with full static checks,
  non-UI builds, and 57/57 security tests.
- Sensitive material scan: Passed.
- Generated `bin`/`obj` cleanup check: Passed after local cleanup.

## Review Notes

- The default readiness profile is `internal-release-candidate`.
- External commercial distribution is intentionally blocked until production
  signing certificate and HTTPS update endpoints are configured.
- The readiness gate is designed to fail external distribution mode until those
  production release materials are supplied.
