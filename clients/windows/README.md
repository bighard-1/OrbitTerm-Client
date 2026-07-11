# OrbitTerm Windows Client

Native Windows client for OrbitTerm.

## Current Phase

Phase 5A: checked Batch command workflow and final personal-use parity hardening.

This directory intentionally starts with strict project boundaries before
feature implementation. The goal is to prevent unsafe shortcuts while the
Windows client is brought up in phases.

## Target Stack

- WinUI 3 / Windows App SDK for the desktop application.
- C# and .NET for application and platform orchestration.
- Rust `orbit-core` through the checked C ABI for SSH, Host Key verification,
  SFTP, terminal channels, monitor snapshots, Docker operations, batch exec,
  crypto, and portable sync helpers.
- Windows Credential Manager or DPAPI-backed storage for local secrets.
- MSIX packaging for commercial distribution.

## Security Baseline

- First SSH connection must verify and present Host Key fingerprints.
- Changed, revoked, unsupported, or unverifiable Host Keys block the connection.
- Terminal, SFTP, Monitor, Docker, and Batch must reuse an active
  HostKeyVerified base session.
- Release builds must not call legacy connection, channel, SFTP, or exec ABI
  symbols.
- Trust All and accept-anyway flows are forbidden.

## Source Layout

```text
clients/windows/
├── OrbitTerm.Windows.sln
├── Directory.Build.props
├── src/
│   ├── OrbitTerm.App/
│   ├── OrbitTerm.Application/
│   ├── OrbitTerm.Platform.Windows/
│   ├── OrbitTerm.NativeBridge/
│   └── OrbitTerm.Terminal/
├── tests/
│   └── OrbitTerm.Security.Tests/
├── scripts/
└── docs/
```

## Verification

On macOS/Linux, run the cross-platform portion:

```bash
DOTNET=/path/to/dotnet clients/windows/scripts/check_windows_toolchain.sh
```

On Windows, run:

```powershell
pwsh clients/windows/scripts/check_windows_toolchain.ps1
pwsh clients/windows/scripts/build_windows_core.ps1
```

The full WinUI build requires Windows because the Windows App SDK XAML compiler
is a Windows executable.

## Non-Negotiables

- No raw P/Invoke calls from UI code.
- No legacy ABI calls in production Windows code.
- No credential persistence outside the secure platform store.
- No string parsing of checked FFI envelopes.
- No UI action that bypasses Host Key verification.
