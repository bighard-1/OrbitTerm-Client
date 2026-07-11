# Phase 0A Evidence

## Scope

Phase 0A establishes the Windows client architecture and safety skeleton. It
does not claim a runnable Windows product yet.

## Completed

- Added `clients/windows` source tree.
- Added WinUI shell project placeholder.
- Added application, platform, native bridge, and terminal projects.
- Added checked-only native bridge entry points.
- Added checked envelope decoder with request correlation validation.
- Added bounded terminal backlog primitive.
- Added Windows static scan scripts for PowerShell and Bash.
- Added Windows architecture ADR.
- Wired the Windows static scan into the repository-level security gate.

## Self-Check Commands

```bash
clients/windows/scripts/check_windows_static.sh
PATH=/private/tmp/orbitterm-tools:/Users/cwz/.cargo/bin:$PATH scripts/security/check_all.sh
PATH=/private/tmp/orbitterm-tools:/Users/cwz/.cargo/bin:$PATH ORBITTERM_RUN_OPENSSH_SMOKE=1 scripts/security/run_openssh_smoke.sh
git status --short
```

On Windows after installing the .NET SDK and Windows App SDK workloads:

```powershell
pwsh clients/windows/scripts/check_windows_static.ps1
dotnet test clients/windows/OrbitTerm.Windows.sln
```

## Known Gaps at Phase Completion

- .NET SDK execution was deferred to Phase 0B.
- WinUI compilation must be verified on Windows in Phase 0B.
- Credential persistence is intentionally defined as an interface and is not
  implemented until Phase 0B.
- Terminal rendering is a placeholder; Phase 1 will choose or build the
  production renderer path.

## Review Findings and Fixes

- Finding: the first Windows static scan treated `orbit_ssh_connect_checked_v1`
  as a forbidden legacy `orbit_ssh_connect` reference.
- Fix: the PowerShell and Bash scans now use exact symbol-boundary matching, so
  checked symbols are allowed while legacy symbols remain blocked.

## Verification Results

- `clients/windows/scripts/check_windows_static.sh`: passed.
- Existing static security scans: passed.
- `scripts/security/check_all.sh`: passed, including the new Windows static
  scan section, Rust gates, ABI checks, and Apple gates.
- `ORBITTERM_RUN_OPENSSH_SMOKE=1 scripts/security/run_openssh_smoke.sh`:
  passed for trusted, changed, revoked, and Release legacy no-socket scenarios.

## Progress

Overall Windows client progress: 5%.
