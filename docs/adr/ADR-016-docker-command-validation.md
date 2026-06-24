# ADR-016: Docker Command Validation

- Status: Accepted for A4-Docker-1
- Date: 2026-06-21
- Scope: Rust Core Docker action and logs command validation

## Context

OrbitTerm's Host Key work authenticates the remote SSH endpoint, but it does
not make a shell command safe. The Rust Docker action and logs paths accepted a
container identifier as an arbitrary string and interpolated it into a remote
command. A value containing shell syntax could therefore execute additional
commands on a correctly verified server.

The list and stats paths use static command strings and do not interpolate
input. The Rust Docker API has no rename, update, image-name, logs `since`,
logs `until`, or logs `follow` parameter. The affected Rust surface is:

- `run_action(container_id, action)`;
- `fetch_logs(container_id, tail_lines)`.

Both continue to use the legacy remote-command transport. Migrating that
transport is a separate Host Key bypass patch and is deliberately outside this
P0 injection fix.

## Decision

Introduce a small `DockerCommandValidator` module. Raw strings can enter only
its parsing methods. Command constructors accept the resulting validated
types, so an unchecked container identifier or action cannot be formatted by
the Docker module.

Shell escaping is not the primary defense. Docker parameters have narrow
grammars, so the implementation uses strict allowlists and canonical command
tokens. It does not accept arbitrary flags and never wraps input in `sh -c`.

Validation failures use `DockerValidationError`, whose variants and stable
reason codes contain no submitted value. Existing Rust Docker APIs map those
errors to their existing `OrbitCoreError::InvalidInput` boundary, preserving C
ABI signatures and response behavior without reflecting an attack payload.

## Container ID

The current Rust and Swift action/logs flow uses the `ID` returned by `docker
ps`, not a container name. A valid identifier is therefore:

- 12 through 64 characters;
- ASCII hexadecimal only (`0-9`, `a-f`, `A-F`).

Empty values, whitespace, Unicode lookalikes, path punctuation, quotes,
control characters, and shell metacharacters are rejected. The validator does
not trim input because accepting invisible surrounding data makes policy
ambiguous.

## Container Name

Rust Core does not currently expose a Docker action that requires a container
name, so this patch does not add a broader name grammar. Future rename support
must introduce a distinct validated name type rather than weakening the ID
validator.

## Action Enum

Raw action strings are converted to `DockerAction`. The complete allowlist is:

- `start`;
- `stop`;
- `restart`;
- `kill`;
- `pause`;
- `unpause`;
- `remove`.

Matching is ASCII case-insensitive for compatibility, but whitespace and
compound input are rejected. `remove` maps internally to the fixed command
tokens `rm -f`; callers cannot pass `rm -f` or append another flag.

## Logs Options

The existing logs API receives `tail_lines` as `u32`, so negative values and
string injection are excluded by the Rust and C type boundary. Values from 0
through 10,000 are accepted. Existing behavior is preserved:

- `0` selects 200 lines;
- positive values are capped to an effective 2,000 lines.

Values above 10,000 are rejected rather than silently accepting an
unreasonably large request. The final command can contain only the canonical
decimal integer produced from `u32` and a validated container ID.

Rust Core does not currently support `since`, `until`, timestamps, or follow.
Those options remain unsupported and must receive dedicated typed validators
before any future implementation.

## Rename and Update

Rust Core has no Docker rename or update API. The current Apple client builds
rename and update command strings and sends them through the generic exec ABI.
That remains a Swift-side residual P0 risk because this Rust Docker validator
cannot distinguish generic commands by intent. It is not silently treated as
fixed by this ADR.

A later patch must replace those raw paths with typed Rust APIs. Rename must
validate the old container ID and a separately constrained new name. Update
must expose only typed, allowlisted CPU and memory fields and must never accept
arbitrary Docker flags.

## Command Construction

`ValidatedContainerId`, `DockerAction`, `DockerLogsOptions`, and
`ValidatedDockerCommand` form the construction boundary. Their Debug output is
redacted. Production Docker action/logs code obtains a validated command and
passes only its canonical string to `run_remote_command`.

Static `docker ps` and `docker stats` commands remain unchanged. No raw
container ID or raw action is formatted in `docker.rs`.

## Non-Goals

This patch does not migrate Docker to `run_remote_command_checked`, add a
checked Docker ABI, change C headers, alter Swift/Android/Go, modify Host Key
verification, write Known Hosts, or change Monitor, SFTP, and batch command.
It also does not claim to secure the generic remote-command ABI.

## Testing

Unit tests cover 12- and 64-character IDs, length boundaries, ASCII casing,
whitespace, controls, Unicode lookalikes, quotes, command substitution,
separators, pipes, redirects, paths, action enumeration, logs bounds, exact
canonical commands, stable reason codes, and Debug/error redaction.

Tests also establish that malicious values fail before a
`ValidatedDockerCommand` exists. Existing Docker list/stats and FFI behavior
remain untouched. Default tests require no Docker daemon or SSH server.

## Rollback

Rollback removes the validator module and restores direct interpolation. That
would reopen a remote command-injection P0 and is acceptable only as a local
development bisect, never as a release fallback. The safer operational
rollback is to disable Docker actions and logs while retaining validation.

## Follow-up

The next Docker security patch should expose Docker operations over an Active
`HostKeyVerified` base session and checked exec, while preserving these typed
validators. The Swift rename/update generic-exec paths require dedicated typed
Rust replacements before Release. Batch checked command migration should
follow as a separate multi-host design.
