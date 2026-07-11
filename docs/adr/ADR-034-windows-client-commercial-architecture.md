# ADR-034: Windows Client Commercial Architecture

## Status

Accepted for phased implementation.

## Context

OrbitTerm needs a Windows client that matches the macOS workstation's product
capabilities without copying Apple-specific implementation choices. The Windows
client must preserve the existing checked Host Key security model, reuse the
Rust core where it is the security boundary, and provide a native Windows user
experience suitable for commercial distribution.

The current Apple client uses SwiftUI, SwiftTerm, Keychain, and the checked Rust
C ABI. Those choices do not transfer directly to Windows. A safe Windows port
therefore needs a new presentation and platform layer, while keeping checked
SSH, SFTP, terminal channel, monitor, Docker, exec, crypto, portable sync, and
Host Key trust semantics aligned with `orbit-core`.

## Decision

The Windows client will use:

- WinUI 3 and Windows App SDK for the packaged desktop application.
- C# and .NET for the presentation, application orchestration, and platform
  integration layers.
- Rust `orbit-core` through the checked C ABI as the security boundary.
- Windows Credential Manager or DPAPI-backed storage for credentials and local
  wrapping keys.
- A Windows-owned OrbitTerm `known_hosts` store under the application data
  directory, never the user's OpenSSH known_hosts file.
- MSIX packaging as the primary commercial distribution path.

The Windows client is not allowed to introduce a direct legacy SSH path. All
Terminal, SFTP, Monitor, Docker, and Batch operations must be opened from an
active HostKeyVerified base session.

## Architecture

The source tree is rooted at `clients/windows` and split into explicit layers:

- `OrbitTerm.App`: WinUI shell, views, controls, and resources.
- `OrbitTerm.Application`: platform-neutral workflow orchestration.
- `OrbitTerm.Platform.Windows`: Windows storage, file picking, windowing, and
  notification adapters.
- `OrbitTerm.NativeBridge`: checked C ABI interop, envelope decoding, native
  ownership, and error mapping.
- `OrbitTerm.Terminal`: terminal state, buffer, input, selection, and rendering
  abstractions.
- `OrbitTerm.Security.Tests`: non-UI security and protocol regression tests.

The application layer may depend on native bridge contracts, but UI code must
not call raw P/Invoke functions directly. Raw native calls stay inside
`OrbitTerm.NativeBridge`.

## Security Rules

1. No Windows production code may call legacy symbols such as
   `orbit_ssh_connect`, `orbit_sftp_connect`, `orbit_request_channel`, or
   `orbit_exec_command`.
2. Checked envelopes must be decoded structurally. String parsing of legacy
   `OK:` or `ERR:` responses is forbidden in Windows checked flows.
3. Host Key changed, revoked, unsupported, and failed verification outcomes must
   block. Windows must not provide Trust All or accept-anyway actions.
4. Debug strings and logs must redact passwords, private keys, known_hosts
   paths, command bodies, stdout, stderr, and Docker log bodies.
5. `known_hosts` writes must be app-scoped, permission checked, and atomic.
6. Credential material must not be persisted in JSON, SQLite, plain text, or
   logs.

## UX Rules

The Windows UI should preserve the macOS information architecture while using
Windows-native interaction patterns:

- Left asset sidebar.
- Center terminal workspace with tabs.
- Collapsible right panel stack for Monitor, SFTP, Docker, and Snippets.
- Host Key trust dialogs that are keyboard accessible and screen-reader
  friendly.
- Windows shortcuts and command surfaces instead of Apple-only conventions.

Pixel-level copying of SwiftUI screens is explicitly rejected. Functional
equivalence and native Windows ergonomics take precedence.

## Consequences

This approach costs more than a web shell or direct UI copy, but gives OrbitTerm
a stable security boundary, predictable commercial packaging, and a UI model
that can survive long-term Windows maintenance.

Windows development must proceed by gated phases. Each phase requires tests,
static review, and a written evidence note before the next phase starts.
