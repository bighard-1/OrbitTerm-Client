# ADR-032: OpenSSH Integration Smoke Suite

- Status: Accepted
- Date: 2026-06-23

## Context

ADR-028 through ADR-031 completed Rust Release fail-closed gates, Swift checked
defaults, repeatable security scans, and removal of the production Accept-All
handler. Unit and fake-backend tests prove protocol invariants, but they cannot
prove that a real SSH transport, OpenSSH key encoding, authentication, PTY,
SFTP subsystem, and checked remote commands work together.

A release candidate therefore needs a real OpenSSH smoke without introducing a
public-network dependency, committed credentials, or ordinary-PR instability.

## Fixture Design

`scripts/security/run_openssh_smoke.sh` creates an isolated temporary directory,
selects an ephemeral loopback port, and runtime-generates:

- two Ed25519 host keys for Changed-key simulation;
- one Ed25519 user authentication key;
- an explicit `authorized_keys` file;
- an application-scoped `known_hosts` directory;
- a fake `HOME` and an sshd log.

The generated `sshd_config` listens only on `127.0.0.1`, allows only the current
local test user, requires public-key authentication, uses `internal-sftp`, and
disables forwarding, gateways, tunneling, PAM, and password authentication.
The script traps exit and signals, terminates sshd, and removes the complete
fixture. No private key is committed or reused.

The fixture never reads or writes the user's SSH configuration or known-hosts
file. Rust tests verify that the supplied known-hosts path and fake `HOME` are
inside the canonical fixture root. Runtime persistence additionally verifies
mode `0600` on Unix.

## Host Key Scenarios

### Unknown and persist

With an absent temporary known-hosts file,
`orbit_test_ssh_connection_checked_v1` must return `host_key_challenge` with the
matching request ID, host, port, algorithm, and SHA256 fingerprint. The JSON
must not contain the generated public-key body, and sshd must show no accepted
authentication.

The test passes the challenge to
`orbit_hostkey_challenge_accept_and_persist_v1`, requires
`host_key_trust_persisted`, and verifies the private application store was
created. A subsequent checked test connection must return
`connection_test_succeeded`.

### Trusted reusable connection

`orbit_ssh_connect_checked_v1` then authenticates against the persisted key and
returns `connected` with a HostKeyVerified base session. Every service smoke
uses only that typed base session.

### Changed

The script stops host-key A and restarts sshd with host-key B on the same
loopback host and port. Checked connect must return `host_key_blocked` with
reason `changed`, old and new fingerprints, no trust action, and no accepted
authentication.

### Revoked

The script writes a separate mode-0600 `@revoked` record for host-key B and the
same host identity. Checked connect must return `host_key_blocked` with reason
`revoked`, no trust/replace capability, and no accepted authentication.

## Checked Service Smoke

After the trusted reusable connection:

- checked PTY returns `terminal_channel_opened` and is closed through the
  existing cleanup ABI;
- checked SFTP returns `sftp_channel_opened`, lists `.`, and disconnects;
- checked exec runs `printf orbitterm-smoke` and verifies bounded stdout;
- checked exec maps a nonzero command to `exec_command_failed` and rejects a
  multiline command as `invalid_command`;
- checked Monitor returns `monitor_snapshot`, or a stable structured error when
  the fixture platform lacks the Linux sampling commands;
- checked exec probes for the Docker command; Docker list runs only when it is
  present, otherwise the test emits an explicit skip reason.

No checked service calls a legacy connection, mixed-ID resolver, generic legacy
channel, or legacy exec path.

## Release Legacy No-Socket Proof

A no-feature Release test records sshd's loopback connection count, invokes
legacy SSH test/connect, SFTP connect, and exec C ABI symbols, and requires
`ERR:legacy_network_disabled` with no new socket. It then invokes a checked test
connection and requires a new sshd connection and an Unknown challenge. This
proves the fixture is observable while legacy calls remain stopped before
handler construction or networking.

Static scans continue to require that public source has only the checked
handler and that the insecure migration handler is feature-gated.

## Execution and CI

Ordinary `cargo test --all-targets` sees two ignored tests and never starts
sshd. A release candidate runs:

```bash
cd OrbitTerm-App
ORBITTERM_RUN_OPENSSH_SMOKE=1 scripts/security/run_openssh_smoke.sh
```

Without the opt-in variable the script exits successfully with an explicit
skip. With opt-in, missing `sshd`, `ssh-keygen`, Python, or Cargo is a failure.
The GitHub Actions `openssh-release-candidate-smoke` job runs only under
`workflow_dispatch`; it needs no secrets and uses no external service.

## Security Constraints

- listen only on IPv4 loopback;
- allocate a high ephemeral port;
- generate all keys at runtime;
- store all files below a mode-0700 temporary root;
- use an application-scoped temporary known-hosts path;
- set a fixture-local fake `HOME`;
- disable password/PAM authentication and network forwarding;
- never print private keys, credentials, complete public keys, command output,
  or Docker logs;
- clean up on success, failure, and signals.

The static gate rejects committed private-key PEM markers and user-known-hosts
references in the integration test and script.

## Known Limitations

Monitor sampling is Linux-oriented, so macOS sshd may return a structured
platform-command error rather than a snapshot. Docker is optional because the
command or daemon is not guaranteed on a CI runner. The suite validates one
local user and Ed25519; broader algorithm and platform matrices remain separate
hardening work.

Docker rename/update remains disabled pending its typed checked C ABI. Batch
targets without a verified base remain fail closed pending multi-target Host
Key preflight UI.

## Rollback

The optional workflow job or fixture script may be adjusted for OpenSSH runner
changes, but release evidence must retain Unknown, persist/trusted, Changed,
Revoked, checked service, and legacy no-socket assertions. Rollback must not
replace the fixture with a third-party SSH service, commit a private key,
broaden an Accept-All allowlist, or make ordinary tests contact a network.

## Release Checklist

Before public release, archive successful output from the standard security
gates and this OpenSSH smoke. Any skipped Docker or platform-limited Monitor
step must include its explicit reason. A failed Host Key, PTY, SFTP, checked
exec, or legacy no-socket assertion blocks the release candidate.
