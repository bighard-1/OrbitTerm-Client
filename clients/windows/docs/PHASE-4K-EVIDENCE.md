# Phase 4K Evidence: Checked Docker Stats Snapshot Entry Point

Date: 2026-07-09

## Scope

- Added a checked Docker stats refresh entry point to the Windows client.
- Kept the feature read-only and manual.
- Did not enable Docker logs, actions, rename, update, or background polling.

## Implementation Evidence

- NativeBridge calls `orbit_docker_stats_checked_v1` and decodes
  `docker_stats` envelopes.
- Docker stats payload validation requires host-key verified security
  generation, a valid base session ID, bounded stats count, hex container IDs,
  finite CPU values, valid memory percentages, and bounded text fields.
- Application maps checked envelopes into `DockerStatsResult` and rejects
  mismatched envelope kinds or base session IDs.
- Presentation exposes a Docker stats command, summary, and bounded read-only
  stats list.
- Workspace tabs preserve Docker stats state when switching tabs.
- Session end clears Docker stats and disables refresh commands.
- Windows UI exposes Docker `Refresh Stats` and Runtime panel stats controls.

## Self-Review

- Production Docker stats calls use `orbit_docker_stats_checked_v1`.
- Legacy Docker stats remains forbidden through `ForbiddenLegacyAbi` and is not
  used by the new presentation or application paths.
- No Docker logs, stdout, stderr, credentials, raw commands, or remote file
  paths are exported through this feature.
- Remote host connection details were not written into project files.

## Verification

- Local Windows-client toolchain gate: passed.
- Local Windows security tests: passed, 69 total, 0 failed.
- Local non-UI builds: passed with 0 warnings and 0 errors.
- Local WinUI build: skipped on Darwin by the validation script because Windows
  App SDK XAML compilation requires Windows.
- Remote Windows security tests: passed, 69 total, 0 failed.
- Remote Windows full WinUI build: passed with 0 warnings and 0 errors.
- Remote Windows toolchain gate: passed.

## Result

Phase 4K passed local validation and remote Windows validation.
