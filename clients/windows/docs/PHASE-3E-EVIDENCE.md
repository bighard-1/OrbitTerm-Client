# Phase 3E Evidence: Redacted Diagnostics Bundle

Date: 2026-07-02

## Scope

- Added an Application-layer diagnostics bundle contract.
- Added runtime and session diagnostic snapshots.
- Added JSON serialization with stable snake_case fields.
- Redacted usernames, known_hosts paths, remote paths, and command text.
- Kept terminal content and SFTP file content out of diagnostics.

## Safety Notes

- Diagnostics are local data structures only in this phase.
- No crash-reporting vendor or network transport is enabled.
- Credentials, private keys, passphrases, known_hosts paths, terminal content,
  command text, and remote file paths must not appear in exported diagnostics
  JSON.

## Validation

- Local Windows-client toolchain gate: passed.
  - Cross-platform static checks passed, including update channel metadata
    validation.
  - Windows non-UI projects built successfully.
  - `OrbitTerm.Security.Tests`: 57 passed, 0 failed.
- Remote Windows toolchain gate: passed.
  - Test execution stayed inside the authorized Windows validation root.
  - Windows static checks passed.
  - Windows non-UI projects built successfully.
  - `OrbitTerm.Security.Tests`: 57 passed, 0 failed.
- Self-review finding fixed.
  - Initial diagnostic test overreached by rejecting the JSON field name
    `known_hosts_path`.
  - The test was corrected to reject sensitive path values while allowing the
    redacted field name.
- Sensitive literal scan: passed.
  - No real remote test address or real password literal was found in Phase 3E
    production diagnostics code, tests, or documentation changes.
  - Sensitive-looking strings are limited to test fixtures and documentation
    that prove exported diagnostics redact them.
- Build artifact cleanup: passed.
  - No local Windows client `bin` or `obj` directories remain after cleanup.
  - Windows client file count after cleanup: 139.
