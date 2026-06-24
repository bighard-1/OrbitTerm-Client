# ADR-029: Swift Release Checked Default and Legacy Compile Guards

- Status: Accepted
- Date: 2026-06-23

## Context

ADR-028 made Rust public Release builds reject legacy networking before TCP, SSH authentication, or channel creation. Swift still selected the legacy path when `CheckedConnectionMode.disabled` was used, so the application layer could continue invoking deprecated APIs and present legacy-only features.

Rust fail-closed behavior is defense in depth, not permission for Swift to keep selecting unsafe paths. Public builds must make the checked connection flow the only constructible production policy.

## Decision

### Connection policy

`ConnectionSecurityPolicy.checkedRequired` is the application default in every normal Debug and Release build. The ambiguous `disabled` state is removed.

`legacyInternal` only exists when both `DEBUG` and `ORBITTERM_INTERNAL_LEGACY_NETWORK` are compiled. No UserDefaults value, environment variable, remote configuration, or runtime setting can create this case. The repository's standard schemes do not define the internal flag.

Release targets define `ORBITTERM_PUBLIC_RELEASE` for diagnostics and future static checks. They never define the internal legacy flag.

### SessionManager

SSH connections use `HostKeyTrustCoordinator`, checked connect, and checked PTY by default. Failure, cancellation, Unknown/Changed/Revoked handling, or terminal-open failure never falls back to legacy SSH or generic channel creation.

The legacy SSH orchestration and Telnet connector are compiled only for an explicit internal legacy build. Public Telnet requests fail closed with a user-readable message.

### Wrapper classification

Dangerous network/channel wrappers include legacy SSH connect/test, SFTP connect, generic channel request, generic exec, Monitor stats, and Docker remote operations. Their C calls are inside the internal legacy compilation condition, and Release stubs cannot initiate networking.

Checked-compatible operations remain available because checked-created terminal and SFTP IDs still use existing read/write/resize/file-operation ABIs. Disconnect, close, and cleanup also remain available in every build.

### Add Server and Quick Key

The standalone Add Server connection-test button is disabled in public builds. Server identity is instead verified by Save and Connect through the checked Host Key flow. This avoids introducing a second Host Key coordinator in this patch.

Remote Quick Key testing and deployment are disabled in public builds. Local key import and storage remain available. A future checked key-deployment design may use a verified base session and bounded checked exec, but public builds do not fall back to legacy SFTP or exec.

### Telnet

Telnet is hidden from protocol selection and settings in public builds. Existing stored Telnet entries cannot connect. Telnet remains an explicitly insecure internal-only capability pending a separate protocol policy.

### Side services and Batch

Standalone SFTP, Monitor, and Docker default to checked-required policy. They require a verified workspace/base session and do not read credentials to create an independent connection. Monitor does not silently reconnect.

Batch executes only targets with verified base sessions. Unverified targets remain fail-closed. Docker rename/update stays disabled until typed checked C ABI support exists.

## Build strategy

Public and normal development builds use checked-required behavior. An internal regression build may explicitly add both compilation conditions:

```text
DEBUG ORBITTERM_INTERNAL_LEGACY_NETWORK
```

The internal flag is intentionally absent from `project.yml` and shared schemes. It must never be added to Release, driven by runtime configuration, or distributed publicly.

## Local static scans

Before release, verify that the old checked-migration flag and ambiguous mode names are absent, and review every dangerous symbol occurrence as internal-guarded:

```bash
rg -n 'ORBITTERM_INTERNAL_CHECKED_CONNECTION|debugInternalOnly|CheckedConnectionMode' OrbitTerm
rg -n 'orbit_(ssh_connect|test_ssh_connection|sftp_connect|request_channel|exec_command|fetch_system_stats|fetch_docker_)' OrbitTerm --glob '*.swift'
xcodebuild -showBuildSettings -project OrbitTerm.xcodeproj -scheme OrbitTerm_macOS -configuration Release | rg 'SWIFT_ACTIVE_COMPILATION_CONDITIONS'
```

Release Swift object files must not contain undefined references to dangerous legacy symbols. Checked symbols and cleanup/operation symbols are expected.

## Testing

Unit tests assert checked-required defaults, checked service policy, no fallback, Host Key state separation, typed IDs, and Batch fail-closed behavior. macOS and iOS Debug and Release builds are required. An explicit internal Debug compile verifies that the guarded legacy regression path remains buildable without becoming a normal scheme.

## Consequences

Add Server standalone testing, Quick Key remote deployment, Telnet, and Docker rename/update are unavailable in public builds. This is intentional fail-closed behavior rather than an availability regression.

ADR-031 completes the Rust follow-up: normal Debug and Release builds no longer compile an Accept-All handler. The insecure migration handler requires the explicit Rust `legacy-network-internal` feature in addition to Swift's internal-only compilation condition.

## Rollback

Rollback must not restore a public runtime legacy switch. If checked rollout debugging is necessary, use an explicitly compiled internal Debug build. Public Release remains checked-required.
