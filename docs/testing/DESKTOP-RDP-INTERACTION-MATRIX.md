# Desktop RDP interaction parity matrix

This matrix is the shared release contract for RDP asset activation and session
lifecycle on macOS, Windows and Linux. The container is intentionally native to
each platform: macOS/Linux use an embedded workspace tab, while Windows uses an
isolated native RDP host window. That container difference must not change the
user-visible lifecycle, safety policy or recovery result.

## Product contract

| ID | Scenario | Shared expected result | macOS | Windows | Linux |
|---|---|---|---|---|---|
| DRI01 | First double activation | Exactly one connection starts immediately; there is no inert tab/window. | Embedded tab | Isolated host window | Embedded tab |
| DRI02 | Duplicate activation during start/auth | The second event is coalesced and cannot cancel, restart or hide progress for the first. | Per-workspace launch gate | Per-asset launch lease | Synchronous `Starting` registry phase |
| DRI03 | Activation after connected | Return to the existing session instead of creating a duplicate. | Select existing tab | Restore/focus existing host | Select existing tab |
| DRI04 | Independent assets | Starting or reconnecting one asset cannot block, select or replace another asset. | Independent workspace IDs | Independent asset leases/hosts | Independent workspace IDs |
| DRI05 | Unknown certificate | Show endpoint identity and fingerprint; continue once or cancel. Never trust silently. | Native alert | Native RDP certificate UI | Native dialog |
| DRI06 | Certificate trust scope | Make the acceptance scope explicit. Session-only acceptance may prompt again for a fresh engine; stored unchanged trust may skip confirmation; a changed certificate must always prompt again. | Accept once per fresh engine | Windows RDP trust handling | Stored trust or explicit dialog |
| DRI07 | Authentication failure | Show an authentication-specific, user-safe message and keep an explicit retry path. | Workspace overlay | App/host feedback | Workspace overlay/dialog |
| DRI08 | Network/port failure | Distinguish reachability from credentials without exposing native exception text. | Workspace overlay | App/host feedback | Workspace overlay/dialog |
| DRI09 | Explicit disconnect | Stop the current session and any pending reconnect; retain the asset container for manual recovery where native. | Tab remains | Host window close control or the parent asset menu can disconnect and close the isolated host | Tab remains |
| DRI10 | Manual reconnect | Reuse the saved asset and protected credential; one action starts one retry. | Existing controller or fresh engine | Existing native host retry | Existing workspace/canvas |
| DRI11 | Close | Release engine, input capture and sensitive transient state; a later activation is a fresh session. | Close tab | Close isolated host | Close tab |
| DRI12 | Background failure | Do not steal foreground selection, focus, fullscreen or shortcut ownership. | Workspace isolation | Separate process/window | Workspace isolation |

## Failure vocabulary

All three clients map native errors into these bounded categories before user
presentation: component unavailable, invalid target, certificate rejected,
authentication failed, network unavailable, timeout, protocol/security failure,
cancelled and unknown. Messages may follow platform writing conventions but
must identify the same corrective action. Native error strings, credentials,
hostnames and remote content must not enter analytics or persistent diagnostics.

## Automated release gates

- Lifecycle state machines reject revival after `Closed` and preserve explicit
  certificate/authentication phases.
- Duplicate launch tests cover starting, authenticating, awaiting decision and
  connected phases; failure/disconnected states remain manually recoverable.
- Pre-engine failures must publish a visible typed failure. Retrying after a
  failed initial open or an explicit disconnect must reopen the saved target.
- Windows must coalesce an in-flight launch and restore/focus a living host for
  subsequent activation; it must not create a second RDP host for the same asset.
- Windows module fullscreen must retain a small, explicit tool-strip toggle;
  expanding it exposes reconnect, exit-fullscreen, minimize, restore/maximize
  and disconnect/close actions. The parent asset menu must remain a second
  recovery and disconnect path while the isolated host is alive.
- Windows host resizing is local presentation scaling: preserve the negotiated
  desktop aspect ratio, centre the largest complete image in the available
  viewport, enable native RDP zoom so SmartSizing may scale above the negotiated
  desktop size, and reapply SmartSizing after a host resize. Never change the
  remote desktop resolution merely because the local window was resized.
- macOS renders every received FreeRDP frame with bidirectional aspect-fit
  scaling. Its debounced display-control resize may request a matching remote
  canvas when the server supports that channel; unsupported or delayed display
  control must retain complete local aspect-fit rendering without cropping.
- macOS releases every tracked remote modifier and pressed pointer button when
  the RDP canvas resigns first responder, the application loses key-window
  status or the canvas leaves its window. Returning to the canvas must start
  from a clean input state rather than inheriting a remotely stuck gesture.
- Linux reconnect remains bounded and only transport/DNS/timeout failures are
  eligible for automatic retry.

## Authorised live acceptance

Use only owner-authorised assets. Do not change remote files, settings, services
or clipboard contents.

1. Cold-launch each client, unlock and immediately double-activate one RDP
   asset. Confirm one container and an immediate visible lifecycle transition.
2. Repeat activation during authentication and after connection. Confirm there
   is still one session and that the existing container is selected/focused.
3. Explicitly disconnect, reconnect, close and activate again. Confirm each
   transition is truthful and the application process remains alive.
4. Use an intentionally unreachable, non-production test endpoint to verify
   network feedback. Use a dedicated invalid test credential only where the
   owner explicitly permits an authentication attempt.
5. Keep a second authorised session foreground while the first reconnects;
   verify selection, fullscreen and shortcut ownership do not move.

Record only platform/build ID, case ID, pass/fail, timestamp and sanitized
failure category. Never record credentials, certificate private material,
remote screen contents or user-entered commands.

## 2026-09-08 macOS live acceptance

- Candidate: Apple-silicon Debug build based on `5b7db54` plus the macOS
  focus-loss cleanup in this change. The signed executable SHA-256 was
  `dfe18dea60f2ea17b23c533042385e702bfcec2fcd6e15c3a97bdb2dbd27b944`.
- The bundled FreeRDP runtime probe passed and the complete checked-FFI suite
  passed 303 tests with no failures, including the new deterministic modifier
  and pointer-release plan test.
- The owner-authorised Windows 11 test asset opened from a cold application
  session with one double activation. The native certificate sheet exposed the
  target identity and fingerprint; explicit session-only acceptance produced
  one connected embedded workspace. No remote file, setting, service or
  clipboard content was changed.
- Live window dimensions moved from 1244×768 to the 1536×768 native zoom size,
  returned to 1244×768, and reached the enforced compact size of 980×732. The
  right tool column collapsed responsively at the compact width. The RDP
  workspace stayed `connected` and frame sampling returned to 60 FPS after
  every transition.
- RDP module fullscreen entered and exited without closing the application or
  replacing the active workspace. Moving focus from the remote canvas to
  Finder and back kept the same process and connected workspace; the new
  cleanup path releases held modifiers and pointer buttons on that transition.
- Manual reconnect created a fresh engine, repeated the certificate prompt as
  required by session-only trust, and returned to `connected` after a second
  explicit acceptance.
- The application intentionally sets the protected window's sharing type to
  disallow screen capture. Consequently remote pixels were not retained as
  test artifacts; evidence was limited to accessibility lifecycle state,
  process identity, frame-rate state and captured window geometry.
