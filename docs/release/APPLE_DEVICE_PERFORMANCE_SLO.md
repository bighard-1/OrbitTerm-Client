# Apple device performance SLO evidence

## Purpose and scope

This gate records release-candidate performance on a real macOS machine and a
real iPhone or iPad. It is intentionally separate from deterministic resource
tests: CPU, physical memory and frame pacing depend on the device and cannot be
truthfully proven by a simulator or a synthetic SSH endpoint.

The evidence contains only scenario identifiers and numeric metrics. It must
not contain an account, endpoint, path, command, terminal output, token,
private key, device UDID or screen recording. Keep raw `.trace` files as
restricted release artifacts; never export them through Diagnostics.

## Required scenarios

Run every scenario three times on an idle, plugged-in device. Use the median
response time, average CPU and worst peak footprint/FPS/hitch count. Do not
compare a remote server outage or WAN packet loss to a client rendering SLO.

| Scenario | User action / measured completion | Response SLO | CPU / footprint ceiling | Frame SLO |
| --- | --- | ---: | --- | --- |
| `cold_launch` | Tap app icon to first usable root | 3.5 s | 85% / 360 MiB | >=45 FPS, <=2 hitches |
| `unlock` | Submit valid local unlock to workspace | 2.0 s | 90% / 360 MiB | >=45 FPS, <=1 hitch |
| `terminal_first_frame` | Connect a known healthy SSH asset to first rendered terminal bytes | 3.5 s | 75% / 420 MiB | >=45 FPS, <=2 hitches |
| `terminal_long_output` | 60 seconds of benign continuous output, while scrolling | 250 ms UI response | 80% / 440 MiB | >=45 FPS, <=3 hitches |
| `docker_log_refresh` | Refresh a bounded Docker log view | 3.5 s | 70% / 420 MiB | >=45 FPS, <=2 hitches |
| `monitor_refresh` | Receive and render a monitor sample | 3.5 s | 70% / 420 MiB | >=45 FPS, <=2 hitches |
| `sftp_directory_refresh` | Open a representative directory listing | 3.5 s | 70% / 420 MiB | >=45 FPS, <=2 hitches |
| `sync_round_trip` | Trigger a no-conflict bidirectional sync to completion | 3.5 s | 70% / 420 MiB | >=45 FPS, <=2 hitches |

`terminal_long_output`'s response value is local input/scroll response, not a
remote command round trip. The signposts added by this change mark app launch,
unlock, terminal first frame, Docker, monitor, SFTP and sync boundaries without
recording payload data.

## Capture procedure

1. Build the exact release-candidate SHA and install it on the test device.
2. Open OrbitTerm and leave it in the required starting state.
3. Capture CPU and memory with Activity Monitor:

   ```zsh
   scripts/performance/record_apple_device_slo.sh \
     --scenario terminal_first_frame \
     --device '<device name or UDID>' \
     --output performance-evidence/terminal-first-frame-activity.trace
   ```

4. Repeat the same scenario using `--template 'Animation Hitches'` for frame
   evidence. Read the minimum FPS and hitch count from Instruments; read the
   response interval from the named `com.orbitterm.app / performance` signpost.
5. Summarize the Activity Monitor trace. The command receives only numeric
   results and creates a redacted JSON summary:

   ```zsh
   scripts/performance/summarize_xctrace_activity.py \
     --trace performance-evidence/terminal-first-frame-activity.trace \
     --scenario terminal_first_frame \
     --response-ms 0 --minimum-fps 60 --animation-hitches 0 \
     --output performance-evidence/terminal-first-frame.json
   ```

6. Run the verifier with one JSON file for each required scenario:

   ```zsh
   scripts/performance/verify_apple_device_slo.py performance-evidence/*.json
   ```

The initial `--response-ms 0` placeholder above is only syntactic. Replace it
with the measured signpost duration before validation. The verifier rejects
missing scenarios, incomplete metrics, or any exceeded ceiling.

## Release acceptance

The release owner attaches the eight sanitized JSON summaries, their trace
hashes, the matching Animation Hitches traces and the build SHA to the private
release-evidence store. The signed release lane enables the fail-closed gate:

```zsh
ORBITTERM_REQUIRE_DEVICE_PERFORMANCE_EVIDENCE=1 \
ORBITTERM_DEVICE_PERFORMANCE_EVIDENCE=/restricted/evidence/rc-<sha> \
scripts/security/check_apple_release_gates.sh
```

Missing real-device evidence is a release blocker; local Debug and Simulator
measurements can assist diagnosis but do not satisfy this gate.
