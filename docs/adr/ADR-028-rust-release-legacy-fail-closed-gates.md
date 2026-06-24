# ADR-028: Rust Release Legacy Fail-Closed Gates

## Status

Accepted for Epic A2.5a.

## Context

The additive checked SSH, terminal, SFTP, Monitor, Docker, and Batch APIs are
available, and their Swift Debug/Internal migrations are in place. Public
Release builds still contain legacy C ABI and UniFFI exports that can create an
unverified SSH transport or open a channel on one. A Swift-only switch cannot
protect other native callers, Android artifacts, or future bindings.

The legacy ABI symbols must remain present during migration to avoid dynamic
link failures. Retaining a symbol does not imply retaining its network
capability.

## Decision

`LegacyNetworkGate` is the single compile-time policy boundary for legacy
network and channel creation.

- Normal Debug and Release builds reject legacy behavior.
- An internal migration build may opt in only with the explicit
  `legacy-network-internal` Cargo feature.
- A normal `cargo build --release` does not enable the feature and rejects
  legacy behavior.
- Environment variables, remote configuration, Swift flags, and runtime state
  cannot change the Rust decision.
- The stable error code is `legacy_network_disabled`.

The internal feature is intentionally named as a legacy capability rather than
as a security mode. Public release tooling must never enable it.

## C ABI Policy

The following legacy C ABI functions check the gate before parsing caller
pointers, resolving a session, or invoking a backend:

- `orbit_test_ssh_connection`
- `orbit_ssh_connect`
- `orbit_sftp_connect`
- `orbit_request_channel`
- `orbit_exec_command`
- `orbit_fetch_system_stats`
- `orbit_fetch_docker_containers`
- `orbit_fetch_docker_stats`
- `orbit_fetch_docker_logs`
- `orbit_docker_action`

Their signatures and symbols are unchanged. Public Release returns the legacy
wire-compatible value `ERR:legacy_network_disabled`, allocated through the
existing Rust C-string ownership model and released with `orbit_free_string`.
Checked JSON ABI functions are unchanged.

## UniFFI Policy

Equivalent legacy Rust/UniFFI exports check the same gate and return the typed
`OrbitCoreError::LegacyNetworkDisabled`. This includes legacy test connection,
SFTP connect, generic channel request, generic exec, Monitor, and Docker
exports. The exports remain present.

## Helper-Level Defense

Entry-point checks are not the final boundary. The legacy physical connection
helper, mixed-ID resolver, legacy terminal opener, generic remote-command
helper, Monitor sampler, and Docker command helpers also check the central
gate. Public Release therefore fails before TCP/KEX/auth, subsystem request,
PTY request, shell request, exec request, or Monitor ping even if a future
caller bypasses an FFI wrapper.

Checked modules continue to use their base-only resolver and verified-session
gate and do not call the mixed-ID resolver.

## Existing Operation ABI

Checked Swift SFTP and terminal paths intentionally reuse existing operation
and cleanup ABI. Those symbols cannot be disabled wholesale.

In public Release:

- SFTP data and mutation operations require `SftpSessionSource::Checked`, an
  active HostKeyVerified base session, and the original security generation.
- Terminal write and resize require `TerminalChannelSource::Checked`, an active
  HostKeyVerified base session, and the original security generation.
- Legacy or unknown operation sources fail closed.
- Internal feature builds preserve the existing legacy operation behavior.

SFTP list/read/write/upload/download/delete/rename and related calls all obtain
their session through the same source-aware SessionPool lookup.

## Cleanup Allowlist

Cleanup does not create authority and must remain available to avoid leaks.
SFTP disconnect, terminal close, and base SSH disconnect do not consult the
legacy network gate. They may close checked or legacy resources that already
exist.

## SFTP mkdir/create/chmod

These operations historically execute a remote shell command after resolving
an SFTP session. They now require the same source-aware SFTP operation check
and use a dedicated transport helper after that validation. They cannot call
the public Release-disabled generic legacy exec helper. Legacy SFTP metadata is
rejected in public Release; checked metadata is revalidated before the channel
is opened.

## Accept-All Boundary

ADR-031 supersedes this temporary boundary. The Accept-All handler now lives
only in a file-level `legacy-network-internal` module, and normal Debug and
Release builds do not compile it. The checked connection path continues to use
`CheckedHostKeyHandler` only.

## Tests and Release Harness

The default Debug suite verifies fail-closed policy decisions, stable/redacted
errors, checked and legacy metadata behavior, lifecycle revalidation, and
cleanup behavior.

The public Release harness is:

```bash
cargo test --release --all-targets
```

With no internal feature it directly calls all gated legacy C symbols using
null or unknown inputs and requires `ERR:legacy_network_disabled`. This proves
the gate runs before pointer parsing and session lookup. It also invokes the
physical-connect, mixed-resolver, remote-command, PTY, Monitor, and Docker
helpers with synthetic backends and requires the typed disabled error. The
same Release suite runs all checked API tests.

Internal behavior can be verified explicitly with:

```bash
cargo test --features legacy-network-internal legacy_network_tests
```

Header C11 compilation and static/dynamic symbol checks verify that both legacy
and checked ABI symbols remain exported.

## Rollback

Rollback may remove the gate calls and feature while preserving the ABI, but
that re-enables Release network bypasses and is not an acceptable public
release state. A safer operational rollback is to keep the Rust gate and defer
the public release until the Swift checked-default migration is repaired.
