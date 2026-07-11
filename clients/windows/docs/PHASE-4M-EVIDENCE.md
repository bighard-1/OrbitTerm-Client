# Phase 4M Evidence: Guarded Docker Start Stop Restart Actions

Date: 2026-07-09

## Scope

- Added guarded Docker start, stop, and restart actions to the Windows client.
- Required an active verified SSH session and an explicitly selected container.
- Did not enable remove, kill, pause, unpause, rename, update, or free-form raw
  action strings.

## Implementation Evidence

- NativeBridge calls `orbit_docker_action_checked_v1`.
- NativeBridge validates requested container IDs as bounded hex values.
- NativeBridge allows only `start`, `stop`, and `restart`.
- Docker action result payload validation requires host-key verified security
  generation, valid base session ID, bounded hex container ID, allowed action,
  and `completed` status.
- Application maps checked envelopes into `DockerActionResult` and rejects
  mismatched envelope kind, base session ID, container ID, or action token.
- Presentation exposes three fixed commands: Start, Stop, and Restart.
- Windows UI exposes only Start, Stop, and Restart for the selected container.

## Self-Review

- Production Docker action calls use `orbit_docker_action_checked_v1`.
- Legacy Docker action remains forbidden through `ForbiddenLegacyAbi`.
- No remove, kill, pause, unpause, rename, update, or raw Docker command input
  was enabled.
- Remote host connection details were not written into project files.

## Verification

- Local Windows-client toolchain gate: passed.
- Local Windows security tests: passed, 71 total, 0 failed.
- Local non-UI builds: passed with 0 warnings and 0 errors.
- Local WinUI build: skipped on Darwin by the validation script because Windows
  App SDK XAML compilation requires Windows.
- Remote Windows security tests: passed, 71 total, 0 failed.
- Remote Windows full WinUI build: passed with 0 warnings and 0 errors.
- Remote Windows toolchain gate: passed.

## Result

Phase 4M passed local validation and remote Windows validation.
