# ADR-030: CI Static Scans and Release Gates

- Status: Accepted
- Date: 2026-06-23

## Context

ADR-028 made Rust public Release builds reject legacy networking before a socket, SSH handshake, authentication, or remote channel is opened. ADR-029 made checked connection policy the Swift public Release default and compile-guarded internal legacy networking.

Those controls were previously verified with manual commands. Manual verification is not a durable release boundary: it can be skipped, use a stale Apple static library, overlook Header drift, or inspect exported symbols without checking what Swift actually references.

## Decision

### Local gate structure

The canonical local entry point is:

```bash
scripts/security/check_all.sh
```

It composes four independently runnable checks:

```text
check_static_scans.sh
check_rust_release_gates.sh
check_symbols.sh
check_apple_release_gates.sh
```

All scripts derive paths from their own location, use `set -euo pipefail`, avoid runtime security switches, and return nonzero on a failed gate. Cargo is forced offline inside the gates; CI fetches locked dependencies and installs Rust targets before invoking them.

### Rust gates

The Rust gate runs formatting, all-target Debug tests, all-target Release tests, an explicit Release C ABI fail-closed harness, an internal-feature policy smoke, clippy with warnings denied, and Debug/Release builds. Release tests prove legacy C ABI calls return `ERR:legacy_network_disabled` before pointer parsing or backend lookup.

### Header and symbol gates

A temporary strict C11 translation unit includes both the canonical Rust header and Apple forwarding header. The gate rejects independent declarations in the Apple forwarding header.

The host Release dynamic library is inspected with platform-appropriate `nm`. All required legacy symbols must remain exported for ABI compatibility, and all checked v1 symbols must be exported. On Apple, the Release app build supplies the static-link check: Swift object files must reference the checked symbols and must not reference dangerous legacy networking symbols.

Apple's `nm` can fail to parse some Rust static archive object formats when the bundled LLVM reader lags rustc. The gate therefore uses the dynamic library for export completeness and the successfully linked Apple Release app/object files for static-archive consumption.

### Static scans

Swift scans fail on:

- Trust All or Accept Anyway UI text.
- Legacy `OK:` / `ERR:` parsing in checked Host Key code.
- Obsolete checked-migration flags and modes.
- Checked services calling legacy connection, generic channel, exec, Monitor, or Docker APIs.
- Dangerous C calls, `.legacyInternal`, or Telnet construction outside `DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK`.

Rust scans fail when checked modules use the mixed-ID resolver, call legacy remote exec, or log credential/key/path/command/output payloads.

### XcodeGen strategy

`project.yml` now includes the checked FFI XCTest target and scheme as well as the public Release compilation condition. The Apple gate generates a project in a temporary directory, verifies that both generated and checked-in projects contain the same release-security target, scheme, and flag, and runs the generated XCTest scheme.

Byte-for-byte `project.pbxproj` comparison is intentionally not used because XcodeGen object identifiers and unrelated project ordering are not security semantics. The checked project is still compiled directly in Debug and Release.

### A2.5d supersession

ADR-031 removed both source-level blockers previously recorded here. The
production root no longer contains an Accept-All handler, and remote-command
diagnostics expose only command length, exit status, and output byte counts.
`known_blockers.allowlist` is now empty. A separate exact static-scan allowlist
permits only the checked handler's trusted `Proceed` return and the strictly
feature-gated internal migration handler.

### CI workflow

`.github/workflows/security-gates.yml` defines independent Rust and Apple jobs on a public macOS runner. No secrets or external SSH/Docker services are required. The Rust job runs tests, Release harness, static scans, header checks, and ABI export checks. The Apple job builds current Apple Rust archives, runs XCTest and the full macOS/iOS Debug/Release matrix, validates XcodeGen, and scans Release Swift object references.

## OpenSSH release-candidate checklist

External OpenSSH tests remain ignored in normal CI and require an explicitly configured release-candidate environment. Before public release, record evidence for:

1. Unknown host returns a challenge and does not authenticate.
2. Accept-and-persist writes the app trust store and checked reconnect succeeds.
3. Changed host is blocked.
4. Revoked host is blocked.
5. Checked PTY opens and supports read/write/resize/close.
6. Checked SFTP opens from the verified base and supports representative operations.
7. Checked Monitor returns a bounded snapshot.
8. Checked Docker list succeeds without legacy SFTP or exec.
9. Checked Batch exec returns bounded output.
10. Public Release legacy ABI calls do not open a socket.

ADR-032 implements this checklist with a runtime-generated loopback fixture and
an opt-in script. It remains separate from ordinary PR gates and is required
for release-candidate evidence.

## Known limitations

- OpenSSH integration is manual-dispatch/release-candidate only, not run on pull requests.
- Docker rename/update remains disabled in public Release.
- Batch targets without a verified base still fail closed; multi-target challenge aggregation remains future work.

## Rollback

Individual scripts may be reverted if a platform toolchain changes, but security assertions must not be replaced with permissive skips. Public Release must retain the Rust fail-closed harness, Swift checked default, Release object scan, and forbidden Host Key UX scans. A temporary CI incident is handled by fixing or narrowly adapting the checker, not by enabling legacy networking.
