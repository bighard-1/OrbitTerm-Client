# Linux RDP resilience and input matrix

This matrix is the release evidence checklist for the Linux FreeRDP workspace.
Tests must use an explicitly authorised asset and must not alter the target's
files, settings or persisted clipboard data.

## Automated gates

| ID | Scenario | Expected result |
|---|---|---|
| R01 | Initial desktop size | Client requests 1280×720 and scales locally. |
| R02 | 4:3, 16:9, ultrawide and HiDPI mapping | Pointer maps into the remote frame and ignores letterbox bars. |
| R03 | Vertical and horizontal wheel | Direction and wheel axis are preserved. |
| R04 | Focus leaves remote surface | Keyboard modifiers and pressed pointer buttons are released. |
| R05 | Retry backoff | Delays are exactly 1, 2, 4, 8, 15, 30, 30, 30 seconds and then stop. |
| R06 | Retry classification | Transport, DNS and timeout may retry; authentication, certificate and security/protocol failures do not. |
| R07 | Explicit disconnect | Pending automatic retry is invalidated and cannot restart the session. |
| R08 | Disconnected presentation | Last frame is cleared and a visible attempt/status overlay is shown. |
| R09 | Redirection policy | Clipboard, drives, printers, smart cards, serial ports and audio stay disabled. |
| R10 | Shortcut ownership | Local, application and remote routing obey focus and explicit capture. |
| R11 | Local input method | Plain/Shift composition is bounded UTF-16 input; Ctrl/Alt/platform shortcuts bypass the IME; committed text is never logged or persisted. |

## Authorised live gates

| ID | Scenario | Method | Expected result |
|---|---|---|---|
| L01 | Normal connection | Connect to the existing read-only Windows test asset. | NLA completes and a 1280×720 frame is received. |
| L02 | Short transport interruption | On the Linux controller only, temporarily reject traffic to the single asset IP and RDP port and terminate that socket. | Remote input is disabled and reconnect status is visible; no failure storm or app exit occurs. |
| L03 | Network restoration | Remove the exact temporary rejection rule. | A later bounded attempt reconnects and returns to the live frame without user action. |
| L04 | Window size change | Toggle maximized/restored window states while connected. | Remote aspect ratio is retained; controls and pointer mapping remain usable. |
| L05 | Module fullscreen | Enter and exit with the remote surface focused. | Tools start collapsed; a top-centre handle toggles them on click, pointer motion never opens them, and F11 returns to the workstation without exiting the app. |
| L06 | Shortcut capture | Enter RDP module fullscreen; exercise Super, Win+R, Alt+Tab, tools/canvas focus, local dialogs and the release chord; then exit fullscreen. | Fullscreen auto-requests capture only while the connected remote canvas is focused. Local tools/inactive windows release it; canvas focus resumes it. Explicit safety release stays suspended until a deliberate canvas click. Exit restores the windowed preference, which defaults to local system shortcuts. |
| L07 | Scroll and pointer focus | Scroll over a read-only page, move focus outside and return. | Scrolling is smooth and no pointer button remains logically pressed. |
| L08 | Local IME commit | With the remote surface focused, enter Latin and CJK text into a disposable remote input field, then cancel it. | Composed text reaches the remote field; no text appears in diagnostics, audit files or local persistence. |
| L09 | Concurrent session isolation | Keep authorised SSH, Telnet and RDP sessions open, switch repeatedly, and exercise each input surface. | Output, focus, reconnect state and shortcuts remain bound to the selected session. |
| L10 | Remote lock and restart recovery | With separate owner authorisation, lock and restart the Windows test asset without changing its files or settings. | The RDP tab shows an honest disconnected/reconnecting state and recovers through bounded retry or an explicit retry. |

## Safety rules

- Always install and launch the current Flatpak commit before live validation.
- Restrict fault injection to the exact destination IP, TCP port and OUTPUT
  direction. Install a timed cleanup before terminating the socket, verify the
  rule is absent afterwards, and keep SSH/RDP management access out of scope.
- Use `clients/linux/scripts/rdp_transport_fault.sh` for firewall-based tests.
  It installs an independent systemd cleanup timer before the tagged rule,
  inserts the exact rule before UFW's early outbound accepts, removes it on
  every normal exit/signal, rejects pre-existing target rules, and bounds
  disruption to at most 120 seconds.
- Do not invoke Ctrl+Alt+Delete, type into remote forms, change Windows display
  settings, reboot the target or modify remote clipboard/files unless the owner
  explicitly authorises that separate test.
- Record before/interrupted/recovered screenshots plus the installed Flatpak
  commit and non-secret diagnostic codes.

## Phase 20 result notes

- R01–R11 passed in the automated workspace suite. The current build also
  connected to the authorised Windows asset under the restricted link and
  safely transmitted the explicit secure-attention sequence.
- L09 passed for concurrent checked SSH and RDP tabs. Telnet remains covered by
  the isolated loopback protocol tests; no unauthorised clear-text target was
  introduced for a cosmetic live check.
- L08's Unicode conversion, bounds, shortcut bypass and non-persistence rules
  passed automated tests. Live CJK text entry remains pending because there was
  no explicitly disposable remote text field that could guarantee zero change
  to the Windows asset.
- L10 remote restart was not executed. The locale-specific power/restart menu
  could not be selected deterministically through automation; blind navigation
  was stopped rather than risk sign-out, shutdown, password change or another
  unintended remote action. No remote file or setting was changed.

## Phase 21 direct-connection result notes

- The Linux controller initially reset every direct connection to the authorised
  Windows asset before any packet left the host. The cause was one stale,
  host-specific `OUTPUT` rejection rule for `<primary-rdp-host>:3389`; it was not a
  Windows credential, NLA, certificate or OrbitTerm transport defect. The exact
  rule was removed and no persisted copy was found in the inspected system
  firewall/service configuration.
- Direct TCP and TLS preflight then passed. The endpoint presented the expected
  self-signed certificate for `DESKTOP-BH6BIKA`, and the already-open OrbitTerm
  tab reconnected without a proxy or reverse tunnel.
- L01 passed directly. L02 and L03 passed with the bounded fault harness: the
  established socket and reconnect path were both interrupted, FreeRDP reported
  transport failure, the tagged rule was removed after the bounded interval,
  and the same application process automatically returned to a fresh frame. No
  target file or setting was changed. The effective chain-first rule recorded
  nine blocked attempts; the visible overlay reached retry 3/8, and recovery
  completed on the later bounded attempt after cleanup.
- Live evidence used installed Flatpak commit
  `11da5ccfff190af15da3d8b3f99085d82f467cee6c3e094a99010057515d34b6`.
- L05 entry and control auto-hide passed on the direct session. Automated exit
  was not used as release evidence because synthetic Wayland key injection was
  routed according to the current RDP focus and is not equivalent to a physical
  keyboard. The client remained alive and was restored to the normal workspace
  by a clean relaunch after the observation.
- L08 live CJK entry and L10 remote restart remain intentionally pending for the
  same deterministic-input and no-target-change constraints recorded above.

## Phase 22 fullscreen input result notes

- A real focused-surface test found that the RDP drawing-area key controller
  could receive F11 without the window controller observing it. The surface now
  reserves plain F11 while module fullscreen is active and reserves the capture
  release chords in every RDP focus state; corresponding releases are consumed
  locally rather than forwarded to FreeRDP.
- L05 passed on installed commit
  `c22d68ff788183a3a6eea80d4efa38d191cfa014f578355c8940bf8b6f9cb0b1`:
  focused RDP module fullscreen returned to the complete workstation via F11,
  with the same process alive. The explicit capture toggle and
  `Ctrl+Alt+Shift+Esc` release also passed.
- Three later RDP-only interruptions all exposed the bounded reconnect state,
  automatically recovered, and left no tagged firewall rule or timer behind.

## Phase 23 input and focus diagnostics result notes

- Installed Flatpak commit:
  `f41729ba95a692fc17bd3084dd10be9aacb6d93415c6edb692bfb9d0e12c0e9c`.
  The authorised Windows asset connected directly and rendered at 1280×720.
- The RDP diagnostic surface now keeps content-free, in-memory counters for
  key press/release, IME commit events, locally reserved shortcuts, focus
  enter/leave, shortcut capture enable/release and safety release batches.
  It also reports current focus, capture, module-fullscreen and held-pointer
  state. It never records key identity, composed text, credentials or remote
  content, and the counters are discarded with the session metrics.
- Live pointer motion, left/middle/right button, vertical wheel, remote key,
  focus leave/return, explicit shortcut capture and
  `Ctrl+Alt+Shift+Esc` release were observed on the installed build. The final
  snapshot had no rejected input and no held pointer button. The release chord
  incremented the locally reserved count and was not forwarded to Windows.
- Concurrent checked SSH and RDP tabs stayed connected. Switching to SSH
  restored the terminal and SFTP tool context; switching back restored the RDP
  canvas and kept the RDP counters attached to the Windows workspace.
- Focused RDP module fullscreen entered and returned through F11 with the same
  process alive. No Windows file or setting was changed.
- Physical-keyboard compositor ownership for Alt+Tab/Super and live CJK input
  remains a short manual gate: Wayland virtual input is useful for regression
  coverage but is not accepted as equivalent evidence for a physical keyboard
  or a user's IME composition session.

## Phase 24 explicit fullscreen toolbar result notes

- Installed Flatpak commit:
  `4baabcdba64c0699b9ddb6e1f6c3c118a8cb5dc724b2c935072eb5cc5b29d644`.
- Fullscreen starts with only a small top-centre toggle. Clicking it expands
  the toolbar below the toggle; clicking again collapses it and returns focus
  to the remote canvas. Pointer movement no longer reveals the toolbar, and
  no hover/timer-based hide state remains. Windowed mode retains its toolbar.
- Invisible local resize targets are now removed while maximized/fullscreen;
  returning to a normal window restores edge resizing. This fixes interception
  of remote edge input, not merely the visible toolbar overlap.
- Live L05 passed against the existing Windows asset: initial collapse,
  click expansion, explicit collapse, re-expansion, toolbar-button exit and
  focused-canvas F11 exit. Both exits retained application process `1115490`
  and the connected workspace.
- The existing remote command window was maximized and restored by clicking
  its own title-bar buttons, including the restore button at the screen's
  top-right edge. No toolbar appeared from that pointer movement. Its contents
  were left intact; no Windows file, setting or command was changed. The close
  button was intentionally not clicked, to preserve the user's open window.
- Local evidence: `artifacts/phase24-fullscreen-collapsed.png`,
  `artifacts/phase24-fullscreen-expanded.png`,
  `artifacts/phase24-remote-maximized.png`,
  `artifacts/phase24-remote-restored.png`, `artifacts/phase24-exited.png`,
  and `artifacts/phase24-f11-exited.png`.
- Toolbar and resize visibility state tests cover every boolean combination.
  Application tests: 38 passed; strict application Clippy passed. The preceding
  workspace regression run passed 107 tests with 3 opt-in live tests ignored.

## Fullscreen shortcut ownership contract (Phase 25)

- Automatic system-shortcut capture belongs to the connected, focused RDP
  canvas in module fullscreen, not to an unfocused application or a local
  dialog. Windowed mode preserves its separate explicit-capture preference
  (off by default). Temporarily operating the fullscreen toolbar does not
  overwrite that preference.
- F11 remains the local fullscreen escape. Ctrl+Alt+Shift+Esc and compositor
  Super+Esc release the capture. Explicit release is not reversed by incidental
  focus notifications; a deliberate remote-canvas click resumes fullscreen
  capture. Remote Ctrl+Alt+Delete retains its dedicated toolbar action.
- The UI distinguishes a requested inhibitor from a compositor-granted one.
  This follows the [GDK shortcut-inhibition contract](https://docs.gtk.org/gdk4/method.Toplevel.inhibit_system_shortcuts.html):
  the compositor may grant, deny or revoke a request. OrbitTerm does not change
  host-wide keybindings or bypass compositor/user revocation.
- Automated checks cover automatic fullscreen capture, windowed preference
  restoration, loss/recovery of focus, disconnected sessions, explicit release
  suspension, and routing of Alt+Tab, Ctrl+Tab, Win+D/Win+R/Win+Left and
  Ctrl+Shift+Esc while preserving local escape hatches.

## Phase 25 final live results

- Final installed Flatpak commit:
  `72c650f12946f88a52e5d8ac58e1d1099b869673a612375e211e0cc6c52a6d01`.
  Application process `2214893` remained alive throughout the final validation.
- An intermediate build exposed a focus-timing defect: after hiding the tools,
  the hierarchy focus-enter signal could precede the canvas's actual keyboard
  focus property. The final build observes `has-focus` and explicitly refreshes
  capture after returning focus from the toolbar. The previously failing
  show-tools / hide-tools / Win+R path passed without an extra canvas click.
- Final L06 evidence: `artifacts/phase25-final-tools-focus.png` shows the remote
  Run dialog after that toolbar round trip. `phase25-final-alt-tab-held.png`
  shows the Windows task switcher from actual Alt+Tab input, with Alt released
  automatically after the bounded screenshot interval.
- Ctrl+Alt+Shift+Esc released the capture: the next Super key opened Ubuntu's
  overview (`phase25-final-release-local.png`). Returning and deliberately
  clicking the canvas restored compositor-granted capture and remote Win+R
  (`phase25-final-recapture.png`). No text was typed or command executed.
- F11 returned to the normal workstation with the same connected process
  (`phase25-final-exited.png`). The next Super key reached Ubuntu, confirming
  the default windowed preference was restored
  (`phase25-final-windowed-local.png`).
- Opening/closing the local RDP diagnostics and returning to the remote canvas
  restored capture and remote Win+R (`phase25-final-dialog-return.png`). Test
  Run dialogs were cancelled; Windows files/settings and existing user windows
  were not changed. The client was left in its normal connected workstation;
  the temporary input daemon and its socket were removed.
- Full workspace regression: 109 passed, 3 opt-in live tests ignored before the
  final focus-timing amendment. Final application regression: 40 passed; strict
  application Clippy, formatting and whitespace checks passed.
- These live results use bounded Linux virtual input and verify real compositor
  routing/Windows UI effects. A physical-keyboard check through the user's
  actual outer RDP/VM viewer remains recommended: an upstream viewer or host
  shortcut consumed before reaching Ubuntu cannot be forwarded by OrbitTerm.

- Owner acceptance: the user subsequently confirmed physical Win, Win+R and
  Alt+Tab work correctly in RDP fullscreen. That gate is accepted, not pending.

## Phase 26 regression scope

- Keep existing Windows applications/files/settings unchanged. Use only the
  authorised Windows RDP connection and checked Linux SSH assets. Bounded
  transport faults affect only outbound TCP to `<primary-rdp-host>:3389` and have
  both normal cleanup and an independent expiry timer.
- Reproduce and fix background reconnect stealing the selected SSH workspace.
  Explicit user selection may activate a tab; an automatic retry must preserve
  both current workspace and selected asset, including an empty selection.
- Release outgoing remote modifiers/buttons before changing the active session
  or closing it. A background RDP phase change must not clear the active RDP's
  shared pointer state. Closing a background tab must not exit the foreground
  module's fullscreen view or rebuild its terminal grid.
- Live gates: RDP/SSH alternation, terminal splits, repeated RDP fullscreen
  entry/exit, foreground and background RDP interruption/recovery, cancellation
  of pending retry, manual reconnect, and capture release/recovery.
- Multi-RDP selection is covered by a deterministic registry test with two
  distinct RDP IDs and an SSH ID. The only second saved RDP target currently
  available is `Linux-RDP-SelfTest` at `127.0.0.1:3389`, served by the same
  GNOME desktop being used as the controller. It is not an independent target
  and is excluded from the two-independent-desktop acceptance gate to avoid
  recursive desktop capture.

## Phase 26 installed regression results (2026-09-04)

- Installed Flatpak commit:
  `84f4bbeb003f9cf3f65c8fb73eedda2acdf83541780b66833279982fe0cf8b45`.
  The installed application process remained `2310129` across the regression.
  Local and Ubuntu `ui.rs` SHA-256 both match
  `ca414975ea93905a8f11045dae25ffa7d3c75db6744a41f3e9330f240081ceb5`.
- Reproduced the old build's background RDP retry selecting Windows while SSH
  was foreground (`artifacts/phase26-reproduced-focus-steal.png`). The installed
  fix preserves the selected asset, foreground workspace and SSH pane grid.
  An 8-second RDP-only fault recovered while all four SSH panes retained their
  own command targets (`phase26-background-fixed-during.png`,
  `phase26-background-fixed-after.png`). A separate 5-second fault recovered
  without exiting SSH four-pane module fullscreen
  (`phase26-ssh-fullscreen-recovered.png`).
- Five RDP/SSH round trips and ten consecutive RDP fullscreen enter/exit cycles
  completed without application exit or dropped SSH/RDP sessions
  (`phase26-tab-roundtrips.png`, `phase26-ten-fullscreen-cycles.png`). This is a
  bounded focus/session regression, not a long-duration soak or a guarantee
  of terminal scrollback fidelity after resizing/replay.
- With focus in the command pre-input, Ctrl+C stopped the fourth pane's bounded
  loopback ping before its 20-packet limit and returned its shell prompt
  (`phase26-ssh-input-control-c.png`).
- An 8-second foreground RDP interruption exited module fullscreen safely and
  displayed interruption/retry progress (`phase26-foreground-fault.png`). After
  automatic recovery, re-entering fullscreen and Win+R opened the Windows Run
  dialog (`phase26-reconnected-capture.png`); it was cancelled without executing
  its pre-existing history entry.
- During a final 25-second fault, the tab's Disconnect action cancelled pending
  retry (`phase26-cancel-during-fault.png`). After the firewall rule expired and
  a further 16-second observation, the UI remained disconnected and `ss` showed
  no connection to the Windows RDP endpoint
  (`phase26-cancel-after-network-restored.png`). Explicit Reconnect restored the
  existing desktop (`phase26-final-reconnected.png`). Earlier menu automation
  attempts did not activate Disconnect before refresh; those attempts are not
  counted as cancellation passes.
- A bounded virtual-input test held Ctrl on the RDP canvas, selected SSH,
  released Ctrl, returned to RDP and entered fullscreen. Win+R still opened
  the remote Run dialog (`phase26-modifier-handoff.png`). The test used an EXIT
  release trap; the dialog was cancelled and fullscreen exited afterward.
  This verifies this Ctrl handoff path, not every possible held key/button.
- Final installed-source check: 110 tests passed, 3 opt-in live tests ignored
  (41 application tests are included in the 110). Formatting, strict workspace
  Clippy, checked-ABI guard, desktop entry and AppStream validation passed.
  Existing FreeRDP C deprecated-callback warnings remain; this is not a claim
  of a warning-free native dependency build. Logs on Ubuntu:
  `/home/gjhy/phase26-check-installed-source.log`,
  `/home/gjhy/phase26-build.log`.
- Code review additionally covered release of outgoing modifiers/pointer buttons
  before registry mutation, active-only pointer reset, and background-tab close
  not rebuilding/exiting the foreground view. Two independent RDP endpoints
  are covered only by the deterministic registry test, not live acceptance.
- Remaining prerequisite: an authorised second independent RDP desktop. The
  existing self-loop target cannot establish independent-target isolation.
  The user need not repeat already accepted physical Win/Win+R/Alt+Tab tests.
- Final cleanup confirmed no tagged fault OUTPUT rule or cleanup timer,
  the temporary input service inactive, and `/tmp/.ydotool_socket` removed.
  The client was left open in the normal workstation with Windows RDP and SSH
  connected (`phase26-handoff-workstation.png`), same application PID and no
  crash/panic entry in its service journal. Existing Windows files, settings
  and user application windows were left unchanged.

## Phase 27 two-independent-RDP results (2026-09-05)

- Added the owner-authorised `<secondary-rdp-host>:3389` target as `RDP-Secondary`
  under `RDP-Test`, UUID `f9931527-0ff4-4806-8328-aee2f420d4d0`. The password
  credential is stored through the system keyring and is not written to this
  report or the asset JSON. TCP 3389 was reachable before the asset was added.
- First connection required an explicit certificate decision. The presented
  endpoint, certificate subject and issuer identified the new host rather than
  the controller or existing `.245` target. Trust was saved for this explicitly
  authorised endpoint, and NLA established a distinct Windows desktop
  (`artifacts/phase27-second-first-connect.png`,
  `artifacts/phase27-second-connected.png`).
- Ten complete `.245`/`.247` tab round trips retained two simultaneous RDP TCP
  connections and the same application PID (`phase27-ten-rdp-roundtrips.png`).
  Each target then passed five consecutive module-fullscreen enter/exit cycles
  (`phase27-dual-rdp-fullscreen-cycles.png`).
- In each target's fullscreen mode, Win+R opened that target's visually distinct
  Run dialog. Both dialogs were cancelled without executing commands
  (`phase27-primary-win-r.png`, `phase27-secondary-win-r.png`).
- Symmetric isolated faults passed. Blocking and terminating only `.247:3389`
  left `.245` selected and usable while the `.247` tab retried
  (`phase27-background-secondary-fault.png`). Blocking only `.245:3389` left
  `.247` selected and usable (`phase27-background-primary-fault.png`). Both
  background sessions recovered after their eight-second fault expired.
- Disconnecting the background `.245` tab did not replace or rebuild the active
  `.247` desktop; `ss` showed only the intended `.247` connection
  (`phase27-background-primary-disconnected.png`). Explicit reconnect restored
  `.245`; as designed, an explicit user reconnect selects its target.
- A bounded held-Ctrl handoff from `.245` to `.247` used an unconditional key-up
  trap. The `.247` desktop subsequently accepted fullscreen Win+R, with no stuck
  modifier (`phase27-dual-rdp-modifier-handoff.png`). This is evidence for the
  tested Ctrl path, not every possible physical input device or chord.
- While `.247` remained in module fullscreen, an isolated `.245` failure and
  retry did not exit fullscreen or replace `.247`'s frame
  (`phase27-secondary-fullscreen-primary-fault.png`). After recovery and F11,
  both RDP TCP sessions were established, PID `2310129` remained alive, and the
  user was left on `.247` in the normal workstation
  (`phase27-final-dual-connected.png`).
- These tests changed only client asset/session state and temporary, exact-match
  OUTPUT rules on the Linux controller. No file, setting, command or service on
  either Windows target was changed. Existing remote windows were left open.

## Phase 28 lock and restart lifecycle result (2026-09-05)

- L10 passed with the owner's accepted Phase 28 authorisation. `.247` entered
  the Windows lock screen through focused fullscreen Win+L. An explicit client
  disconnect/reconnect used the saved keyring credential for NLA and returned
  to the original session without entering secret text into the remote form.
- `.245`, which has an owner-provided rollback snapshot, was restarted once via
  OrbitTerm's secure-attention control and the native Windows power menu. The
  client showed bounded reconnect progress, `.247` remained online, TCP 3389
  returned after the reboot, and `.245` recovered automatically under the same
  client PID. See `phase28-primary-restarting.png` and
  `phase28-primary-restart-recovered.png`.
- A preliminary text-command attempt did not reboot the host because the local
  CJK input method transformed the text; Windows rejected it as a missing file.
  The dialog was dismissed and the unsafe automation path was not retried. This
  negative result is retained so the lifecycle evidence does not imply that
  arbitrary command text was successfully sent.
- Final cleanup found no `orbitterm-rdp-fault` rule or timer. The temporary
  Phase 27 input service is inactive and its socket removed. Installed Flatpak
  commit remains
  `84f4bbeb003f9cf3f65c8fb73eedda2acdf83541780b66833279982fe0cf8b45`;
  both RDP sockets remain established and the application journal contains no
  crash/panic entry for this run.
