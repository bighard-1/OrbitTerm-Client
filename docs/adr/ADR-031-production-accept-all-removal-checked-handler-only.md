# ADR-031: Production Accept-All Removal and Checked Handler Only

- Status: Accepted
- Date: 2026-06-23

## Context

ADR-028 made public Rust Release builds reject legacy networking before TCP,
KEX, authentication, or channel creation. ADR-029 made checked connections the
only public Swift policy, and ADR-030 automated the release gates. One
production-root `russh::client::Handler` still returned `Ok(true)` for every
server key, however. It was unreachable in public Release but still compiled,
and normal Debug implicitly enabled legacy networking. The legacy remote exec
diagnostic also printed the complete command.

Both were release blockers. Defense in depth requires public artifacts to have
no constructible Accept-All handler, not merely an application path that is
expected not to call it.

## Decision

### Internal-only insecure handler

The former production `OrbitSshClientHandler` is removed. Its migration-only
behavior is isolated in:

```text
orbit-core/src/security/insecure_legacy_host_key_handler.rs
```

The file has a file-level `legacy-network-internal` cfg, the module declaration
has the same cfg, and the type is named
`InsecureLegacyAcceptAllHostKeyHandler`. These names are deliberately blunt.
The handler may be compiled only for explicit internal migration and regression
builds.

Normal Debug and Release builds no longer permit legacy networking. The central
`LegacyNetworkPolicy::current()` returns `AllowedInternal` only when the Cargo
feature is explicitly enabled. Environment variables, runtime configuration,
Swift flags, and `debug_assertions` cannot enable it.

### Checked handler only

Public checked connection and checked connection-test paths construct
`CheckedHostKeyHandler` with a `HostKeyVerificationContext`. The handler returns
true only for `HostKeyVerificationDecision::Proceed`, after recording the
verified key in the per-connection slot. Unknown keys create a challenge;
Changed, Revoked, and unsupported keys block; verification or store failures
fail closed.

SessionPool retains a feature-gated legacy handle variant solely so internal
artifacts can exercise migration behavior. Public builds compile only checked
and test-synthetic handle variants. Legacy C ABI and UniFFI symbols remain
exported, but the existing central gate returns `legacy_network_disabled`
before pointer parsing, session lookup, handler construction, or networking.

### Command-log redaction

Legacy transport diagnostics no longer interpolate command text. When the
explicit internal debug diagnostic is enabled, it reports only:

- command byte length;
- exit status;
- stdout byte count;
- stderr byte count.

It does not print command text, remote output, credentials, host-key material,
or known-hosts paths. No digest dependency is added because length and bounded
execution metadata are sufficient for this diagnostic.

## Static Scan Policy

The A2.5c warning is promoted to a hard failure. The scan allows exactly two
source locations containing `Ok(true)`:

1. the checked handler's trusted `Proceed` branch;
2. the file-level feature-gated insecure internal handler.

The exceptions are exact path-and-context entries in
`scripts/security/static_scan.allowlist`. Any third occurrence, any insecure
handler reference from a checked module, any root production handler, or any
missing cfg guard fails the gate. Test fakes must receive an equally narrow
path/context exception if one is added later. The resolved production
Accept-All and full-command-log entries are removed from
`known_blockers.allowlist`.

The command-log scan also rejects direct command/stdout/stderr interpolation in
Rust diagnostics. Unit tests verify that diagnostic strings exclude the raw
command.

## Cargo Feature Policy

`default = []` remains unchanged. `cargo build`, `cargo build --release`, and
`cargo test --release --all-targets` therefore do not compile the insecure
handler. Internal regression requires an explicit command such as:

```bash
cargo test --features legacy-network-internal legacy_network
```

`cargo clippy --all-features` verifies that internal-only code remains healthy;
it does not model a public artifact. The no-feature Release harness is the
security assertion for public builds.

## Tests and Release Harness

The default Debug and Release suites now exercise the legacy C ABI fail-closed
harness. Helper tests prove that physical connection, mixed-ID resolution,
legacy channel opening, Monitor, Docker, and exec stop before a backend. Existing
checked handler tests cover Unknown, Changed, Revoked, trusted, and store-error
decisions. An internal-feature-only test proves the isolated handler remains
constructible for explicit regression builds.

Required release evidence remains:

```bash
cargo test --release --all-targets
cargo build --release
scripts/security/check_all.sh
```

Header compilation and symbol checks continue to require both legacy and
checked ABI exports. Wire schemas and C ABI signatures are unchanged.

## Consequences

Normal Rust Debug builds can no longer exercise insecure legacy networking by
accident. Developers needing that regression path must opt in explicitly, and
the resulting artifact must not be distributed. Checked production behavior is
unchanged. The only runtime diagnostic loss is raw command text, which was not
safe to retain.

## Rollback

The internal module can be removed entirely when legacy regression coverage is
no longer needed. Rollback must never restore an unguarded Accept-All handler,
make the internal feature default, reintroduce `debug_assertions` as permission,
or log complete commands. If checked connectivity regresses, public release is
paused while the checked path is fixed; it does not fall back to legacy trust.

## Follow-up

The next release-readiness stage should systematize the external OpenSSH smoke
suite: Unknown challenge, accept-and-persist reconnect, Changed and Revoked
blocking, and checked PTY/SFTP/Monitor/Docker/Batch operations. Docker
rename/update may remain disabled until its typed checked C ABI exists, and
Batch targets without verified sessions remain fail closed until preflight UI
is implemented.
