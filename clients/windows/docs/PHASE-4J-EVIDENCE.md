# Phase 4J Evidence: Checked Docker List Entry Point

Date: 2026-07-09

## Scope

- Added a checked Docker container list entry point to the Windows client.
- Kept the phase intentionally read-only: no Docker logs, actions, rename,
  update, or background polling were enabled.
- Reused the existing verified-session boundary and checked envelope decoder.

## Implementation Evidence

- NativeBridge validates `docker_containers` payloads with host-key verified
  security generation, matching base session ID, bounded container count, hex
  container IDs, bounded text fields, and no control characters.
- Application maps checked envelopes into `DockerContainersResult` and rejects
  mismatched envelope kinds or base session IDs.
- Presentation exposes Docker status, summary, and a bounded list model.
- Workspace tabs preserve Docker status and container list when switching tabs.
- Session end clears Docker state and disables refresh commands.
- Windows UI exposes a Docker menu item and Runtime panel button/list.

## Self-Review

- Production Docker list calls use `orbit_docker_list_checked_v1`.
- Legacy Docker functions remain forbidden through `ForbiddenLegacyAbi` and are
  not used by the new presentation or application paths.
- No terminal stdout, stderr, command bodies, credentials, or remote file paths
  are exported through this feature.
- Remote host connection details were not written into project files.

## Verification

- Local Windows-client toolchain gate: passed.
- Local Windows security tests: passed, 68 total, 0 failed.
- Local non-UI builds: passed with 0 warnings and 0 errors.
- Local WinUI build: skipped on Darwin by the validation script because Windows
  App SDK XAML compilation requires Windows.
- Remote Windows security tests: passed, 68 total, 0 failed.
- Remote Windows full WinUI build: passed with 0 warnings and 0 errors.
- Remote Windows toolchain gate: passed.

## Result

Phase 4J passed local validation and remote Windows validation.
