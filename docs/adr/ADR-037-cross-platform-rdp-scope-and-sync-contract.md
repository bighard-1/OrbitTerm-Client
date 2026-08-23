# ADR-037: Cross-platform RDP scope and encrypted asset contract

## Status

Accepted. Supersedes the local-only RDP sync restriction in ADR-036.

## Product scope

OrbitTerm's five planned clients may act as remote-desktop controllers:

- Windows, macOS and Linux desktop clients;
- iOS and Android clients, with landscape enabled only while an RDP workspace
  is active.

The first graphical target scope is deliberately smaller:

- Windows targets use native RDP;
- Linux desktop targets are supported when the target exposes a compatible RDP
  service such as xrdp;
- macOS graphical targets are not supported in this phase.

The macOS client remains an RDP controller for Windows and Linux targets. No VNC
engine or Apple Screen Sharing compatibility layer is included in this phase.
macOS assets remain available through SSH, SFTP, Docker and monitoring.

## Portable contract

1. The portable asset envelope uses `transport: "rdp"`, the destination host,
   port (default 3389), username and the existing encrypted credential fields.
2. RDP assets participate in the same account ownership, encrypted upload,
   merge, conflict and deletion-tombstone rules as SSH and Telnet assets.
3. A client without an RDP engine must preserve and display the asset, but must
   reject connection locally with a capability message. It must never coerce
   `rdp` to `ssh`, silently delete it, or overwrite its transport on sync.
4. Jump-host metadata is valid only for SSH assets. RDP-over-SSH is represented
   by an explicit future remote-desktop gateway profile, not by reusing an RDP
   asset's jump-host field.
5. Clipboard, drive, printer, audio, gateway and display preferences are
   device-local until the versioned remote-desktop preferences extension is
   implemented. Secrets never appear in diagnostics, command-line arguments or
   plaintext `.rdp` files.
6. Unknown future transport values fail closed. They may be retained by the
   encrypted service, but are not made connectable by a client that does not
   understand them.

## Engine delivery order

1. Make all current clients preserve `rdp` assets and enforce capability gates.
2. Harden the existing Windows RDP host and its NLA/certificate workflow.
3. Add FreeRDP-based controller adapters to macOS and the future Linux client.
4. Add FreeRDP-based iOS and Android workspaces with touch pointer, software
   keyboard, safe-area, external keyboard and RDP-only landscape policies.
5. Add optional RDP-over-verified-SSH tunnelling without weakening the checked
   SSH trust boundary.

## Verification gates

- Cross-client encrypted RDP asset round trip, edit conflict and tombstone;
- unsupported-client preservation with no SSH fallback or credential loss;
- NLA, certificate decision, clipboard and redirection policy tests;
- Windows/Linux target matrix across all implemented controller platforms;
- mobile rotation restricted to the active remote-desktop workspace;
- no macOS graphical target shown as supported in UI or documentation.
