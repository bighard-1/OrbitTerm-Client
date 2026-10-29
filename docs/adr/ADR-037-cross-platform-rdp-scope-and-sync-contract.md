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

## Desktop interaction parity

1. Every desktop client presents a visible connection-failure alert instead of
   relying on a status bar. Authentication rejection is distinguished from an
   unreachable RDP service, DNS failure, certificate failure, timeout and
   protocol negotiation failure. Diagnostic text must not contain credentials.
2. Runtime resolution selection is not exposed. Desktop clients request the
   conservative 1280×720 initial desktop and scale it locally into the available
   viewport. An unsupported remote display mode must never terminate an
   otherwise healthy session.
3. RDP module-fullscreen controls auto-hide and reveal from the top edge so they
   do not permanently cover remote content.
4. Shortcut ownership follows focus: the local operating system retains its
   reserved shortcuts unless the user explicitly enables remote capture; app
   shortcuts apply outside the remote surface; ordinary keys go to the focused
   remote surface. Losing remote focus releases captured modifier state. Every
   platform provides an always-local release gesture using its native modifier
   naming.
5. A session that was already connected may perform a bounded automatic
   reconnect after transport, DNS, timeout or otherwise unclassified transient
   failure. Attempts use 1, 2, 4, 8, 15, 30, 30 and 30 second delays. Initial
   connection failures never start the policy. Authentication, certificate,
   cancellation and protocol/security negotiation failures stop immediately
   and require an explicit user decision. The frozen last frame is hidden while
   disconnected, every attempt is visible, and manual disconnect cancels all
   pending attempts.
6. Pointer input includes movement, three buttons, vertical/horizontal wheel
   events and release cleanup when remote focus is lost. Keyboard modifier and
   pointer-button cleanup are best-effort before focus returns to the local
   desktop, preventing a locally interrupted gesture from remaining pressed on
   the remote system.
7. Desktop clients use an automatic quality policy rather than exposing a
   runtime resolution selector. The Linux FreeRDP adapter advertises network
   auto-detection, compression, progressive graphics, heartbeat and memory-only
   bitmap caches while retaining the fixed safe desktop and software rendering
   path. Persistent bitmap caches and every local-resource redirection remain
   disabled.
8. Connection diagnostics distinguish decoded frame activity from actual
   network throughput. They may report frame updates, decoded bytes, negotiated
   resolution, reconnect history and non-secret failure codes, but a static
   desktop with no new frames must never be labelled as a failed or unhealthy
   network by itself.
9. A software-rendered client transports dirty rectangles rather than copying
   the complete desktop after every FreeRDP paint callback. Each session has a
   single-notification mailbox: updates arriving while the UI is busy are
   applied to the latest in-memory canvas and their damage regions are merged.
   The UI consumes at most one merged update per refresh cycle. Resolution
   changes force a complete refresh, queue growth is bounded, and no remote
   pixels are written to disk.

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
