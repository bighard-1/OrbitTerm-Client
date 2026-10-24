# Linux RDP performance and diagnostics matrix

This matrix validates the automatic-quality FreeRDP path without changing the
remote Windows display mode or persisting remote desktop content.

## Automated gates

| ID | Scenario | Expected result |
|---|---|---|
| P01 | Adaptive profile | Network auto-detection, compression, heartbeat and progressive graphics are enabled. |
| P02 | Cache boundary | Bitmap caches are enabled in memory and persistent cache remains disabled. |
| P03 | Resolution boundary | The client still requests 1280×720 and scales locally. |
| P04 | Telemetry window | Frame updates and decoded bytes use a bounded five-second window. |
| P05 | Static desktop | A connected session with no recent frame is labelled “static”, not “failed” or “poor”. |
| P06 | Diagnostic wording | Decoded bytes are explicitly identified as not being network throughput. |
| P07 | History | Disconnect and successful automatic-recovery counts survive a reconnect attempt. |
| P08 | Secret boundary | Diagnostic output contains no password, private key or authentication token. |
| P09 | Dirty rectangle | A partial update changes only its bounded region in the retained canvas. |
| P10 | Mailbox backpressure | Multiple native updates produce one outstanding UI notification and one merged damage region. |
| P11 | Bounds safety | Overflowing, truncated and out-of-desktop damage is rejected without changing the canvas. |
| P12 | ABI boundary | The Rust and C adapters require frame ABI v2, including explicit damage coordinates. |
| P13 | Burst pressure | Ten thousand native updates remain behind one notification and drain as one bounded merged frame. |

## Authorised live gates

| ID | Scenario | Method | Expected result |
|---|---|---|---|
| LP01 | Normal negotiated connection | Connect to the authorised Windows test asset using the current Flatpak. | NLA and certificate verification complete; a 1280×720 frame is rendered. |
| LP02 | Diagnostic surface | Open “自适应 / 连接诊断”. | Resolution, frame activity, engine version, safety policy and history are readable. |
| LP03 | Restricted bandwidth | Route only the test RDP stream through a temporary bandwidth/latency proxy. | UI remains responsive, remote pixels continue updating and the client does not change the remote display mode. |
| LP04 | Complete interruption | Stop only the temporary RDP relay. | Last frame is cleared and bounded reconnect state replaces the desktop. |
| LP05 | Recovery | Restore the relay before the retry budget expires. | NLA and certificate validation repeat and the same workspace returns to connected. |
| LP06 | Cleanup | Remove the exact relay and routing rule, then restart idle. | No test listener, firewall rule or connected RDP session remains. |
| LP07 | Normal-network soak | Keep an authorised session active for 60 minutes while sampling process RSS, CPU, threads and descriptors. | The process remains alive and responsive; resource growth is bounded and diagnostics remain available. |
| LP08 | Visual activity | During the soak, use non-destructive desktop activity or an existing animated surface. | Native update count advances, UI presentation count never exceeds it and merged-update count is internally consistent. |
| LP09 | Fullscreen and focus | Enter/leave module fullscreen and return focus to local controls during the soak. | No exit, stuck modifier, frozen surface or unbounded queue occurs. |
| LP10 | Weak-network soak | Repeat a bounded soak through the loopback-only latency/bandwidth proxy. | Incremental rendering and app input remain responsive without resolution renegotiation. |

`clients/linux/scripts/rdp_network_proxy.py` is the approved LP03 harness. It
binds only to `127.0.0.1`, forwards opaque bytes without logging them, and adds
bounded per-direction delay and throughput pacing. It must be stopped after the
test and must never be exposed on a public interface.

`clients/linux/scripts/rdp_soak_probe.sh` samples only non-secret process
resource counters. The output is suitable for release evidence and never reads
the RDP framebuffer, command line credentials, environment, or network payload.

## Phase 20 bounded weak-network evidence

- Weak-network evidence build commit: `85043d304b0fc887127c45abfe81d38fd4f3751176411cf9e08d91034e7ba3ad`.
  The final input-release pairing build installed after this run is
  `11da5ccfff190af15da3d8b3f99085d82f467cee6c3e094a99010057515d34b6`.
- Test path: loopback-only proxy, 80 ms delay per direction and 524,288 bytes/s
  per direction; only the authorised Windows RDP destination was redirected.
- Duration: 889 seconds, 60 samples at 15-second intervals. The process stayed
  alive at 0.8% sampled CPU. RSS ranged from 433,328 to 491,712 KiB; the change
  includes adding a concurrent checked SSH session, after which RSS stabilised
  near 491 MiB. Threads changed from 54 to 56 and descriptors from 49 to 56.
- Current-build reconnection produced a 1280×720 frame and approximately
  7.4 frame updates/s through the restricted link. Killing only the proxy
  produced the explicit bounded reconnect overlay; restoring the isolated
  baseline relay returned the same workspace to connected.
- Evidence: `artifacts/phase20-rdp-weak-network.tsv` and the corresponding
  `artifacts/phase20-*.png` screenshots. Temporary listeners, routing rules,
  input injection daemon and reverse relay were removed after the run.

## Phase 22 current-build focus and reconnect soak

- Installed Flatpak commit:
  `c22d68ff788183a3a6eea80d4efa38d191cfa014f578355c8940bf8b6f9cb0b1`.
- A hardware-level virtual keyboard exposed that F11 could still reach the
  FreeRDP drawing-area handler while RDP module fullscreen owned focus. The RDP
  surface now independently reserves fullscreen F11 and both documented
  capture-release chords, and consumes their matching release events so no
  modifier can remain pressed remotely. Fullscreen F11 exit passed on the
  installed build without exiting the application.
- The explicit shortcut-capture control and `Ctrl+Alt+Shift+Esc` release path
  passed with the RDP surface focused. Compositor-level Super/Alt behaviour and
  live CJK commit were not promoted to release evidence because the Wayland
  virtual input device split the synthetic combinations through IBus; this is
  not equivalent to a physical keyboard.
- A 1,800-second normal-network soak collected 60 samples on the same process.
  Three exact 8-second RDP-only interruptions ran at minutes 5, 15 and 25. Each
  disconnect released the session from 54 threads/49 descriptors to 48/39, and
  each automatic recovery returned to exactly 54/49 without changing the PID.
- Across connected samples RSS started at 450,704 KiB, ended at 467,824 KiB and
  peaked at 467,968 KiB. The final post-third-recovery plateau was stable rather
  than continuing the earlier step, for a bounded 17,120 KiB start-to-finish
  increase. Sampled CPU declined from 3.4% to 2.2%.
- Evidence: `artifacts/phase22-rdp-soak.tsv`,
  `artifacts/phase22-f11-fixed.png`, and
  `artifacts/phase22-soak-final-online.png`. All tagged firewall rules, timers,
  the temporary input daemon and its socket were removed; the Ubuntu input
  engine was restored to `libpinyin`. No Windows file or setting was changed.

## Phase 23 current-build input diagnostics evidence

- Installed Flatpak commit:
  `f41729ba95a692fc17bd3084dd10be9aacb6d93415c6edb692bfb9d0e12c0e9c`.
- The live diagnostic surface separated accepted remote input into pointer
  motion, button, wheel, key press, key release and composition-category
  counts, and separately counted local shortcut reservations, focus changes,
  capture transitions and safety releases. Only categories and counters exist;
  key values and composed text are not stored.
- After pointer/button/wheel, focus, capture/release and two-session switching,
  diagnostics reported zero rejected input and zero held pointer buttons. The
  same process survived RDP module-fullscreen entry and focused F11 exit.
- Evidence: `artifacts/phase23-diagnostics-input.png`,
  `artifacts/phase23-multisession-ssh.png`,
  `artifacts/phase23-multisession-rdp.png`,
  `artifacts/phase23-rdp-fullscreen.png` and
  `artifacts/phase23-rdp-fullscreen-exit.png`.

## Phase 28 two-RDP lifecycle soak

- Installed Flatpak commit remained
  `84f4bbeb003f9cf3f65c8fb73eedda2acdf83541780b66833279982fe0cf8b45`.
  Process `2310129` already had more than 19 hours of uptime. The independent
  `.247` RDP session was introduced at 09:32 local time; final lifecycle recovery
  completed at 10:40, giving more than one hour of two-target client activity
  with intentional bounded interruptions rather than uninterrupted TCP uptime.
- The final intensive probe ran 1,200 seconds at 15-second intervals and wrote
  80 non-secret samples to `artifacts/phase28-dual-rdp-soak.tsv`. During it, 20
  `.245`/`.247` round trips and 20 total fullscreen enter/exit cycles completed.
  Exact six-second interruptions were injected once per target.
- RSS began at 691,140 KiB and ended at 698,560 KiB (+7,420 KiB). Across 78
  fully-connected samples, RSS averaged 691,663 KiB and ranged from 680,544 to
  699,044 KiB. The final idle plateau was about 698,560 KiB and remained below
  the observed peak. This bounded run finds no monotonic/unbounded growth; it is
  not a proof that leaks cannot occur over longer durations.
- Both connected sessions used 62 threads and 77 descriptors. Each isolated
  transport interruption was sampled at 57 threads and 67 descriptors, then
  returned to exactly 62/77 after automatic recovery. No descriptor or thread
  accumulation followed the faults. Sampled process CPU remained 1.3% (the
  lifetime average reported by `ps`, not an interval-specific CPU trace).
- `.247` passed remote Win+L, explicit disconnect and credential-backed NLA
  reconnection without typing its password into the remote form
  (`artifacts/phase28-secondary-locked.png`,
  `artifacts/phase28-secondary-lock-reconnect.png`).
- The first attempted `.245` reboot command was not executed: the controller's
  active CJK input method transformed the text and Windows returned a plain
  “file not found” dialog. The dialog was dismissed; no unknown executable ran.
  Retrying text automation was abandoned. The authorised reboot was performed
  through OrbitTerm's secure-attention action and the native Windows power menu.
- During the native reboot, OrbitTerm exited module fullscreen and displayed
  retry 3/8 (`artifacts/phase28-primary-restarting.png`). TCP 3389 was down for
  three three-second probes and available on the fourth. The same client PID
  automatically restored NLA and the live desktop, while `.247` stayed connected
  (`artifacts/phase28-primary-restart-recovered.png`). Final resources were again
  62 threads and 77 descriptors.

## Interpretation rules

- “fps” means client frame-update callbacks per second, not monitor refresh rate.
- “incremental decoded bytes/s” measures dirty BGRA pixels accepted from
  FreeRDP before UI composition, not compressed wire throughput. It is useful
  for comparing local copy pressure but is not a network speed test.
- “UI merged presentations” counts composed textures; it must not exceed native
  updates. “Avoided native full-frame copies” estimates savings only across the
  FreeRDP-to-Rust callback boundary from the fixed BGRA canvas size minus dirty
  pixel bytes. GTK's immutable presentation texture remains a separate full
  canvas operation, and neither value is a network-bandwidth claim.
- A static Windows desktop can legitimately produce zero frame updates.
- Weak-network tests must affect only the authorised RDP destination and must
  never delay SSH management traffic or change the Windows host configuration.
