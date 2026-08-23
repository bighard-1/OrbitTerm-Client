# ADR-036: Windows remote-access capability boundaries

## Status

Accepted for staged Windows implementation. Apple implementation is explicitly deferred.

## Context

OrbitTerm is an SSH workstation whose terminal, SFTP, monitor, Docker and batch
features all open channels from a host-key-verified `orbit-core` base session.
Windows now also needs reusable SSH key management, SSH port forwarding and an
embedded RDP experience without creating a second, weaker trust path.

## Decision

1. The Windows SSH key library is current-user DPAPI protected. Metadata,
   assignments, private material and passphrases are encrypted together. Private
   material is never displayed, copied, logged or exported by default.
2. Assigning a library key replaces only the asset's private-key fields and
   preserves its password fallback. A key cannot be deleted while assigned.
3. Local, remote and dynamic forwarding are versioned application contracts.
   Runtime channels must be opened only from an active host-key-verified Rust
   base session. The UI cannot launch `ssh.exe` as an alternate transport.
4. Tunnel listeners default to loopback. Binding to a non-loopback interface
   requires a per-rule warning and explicit confirmation. Remote forwarding is
   treated as higher risk and is never enabled silently.
5. Windows embedded RDP uses the Microsoft Remote Desktop ActiveX control in a
   dedicated native window. Credentials remain in Windows protected storage;
   they are not passed on command lines or written to `.rdp` files.
6. NLA is mandatory. Clipboard, drive and printer redirection are individually
   configurable; enabled redirections are shown before connection. RDP-over-SSH
   reuses a loopback local tunnel created by rule 3.
7. This document's original local-only RDP rule is superseded by ADR-037. RDP
   asset metadata and credentials now use the reviewed encrypted portable asset
   envelope; port-forwarding runtime state remains local-only.

## Delivery order

1. DPAPI key library and asset assignment UI.
2. Checked Rust direct-tcpip channel, bounded listener lifecycle, native ABI and
   local-forward UI; then remote and SOCKS5 modes.
3. Native Windows RDP window, direct connection first and verified SSH-tunnel
   connection second.

## Verification gates

- duplicate/private material tests and DPAPI round trip on Windows;
- checked-session rejection, loopback defaults, cancellation and disconnect
  cleanup for tunnels;
- no credentials in process arguments, files, logs or diagnostics;
- Windows 10/11 x64 UI, DPI, keyboard and screen-reader checks;
- RDP NLA and redirection-warning checks against a disposable Windows target.
