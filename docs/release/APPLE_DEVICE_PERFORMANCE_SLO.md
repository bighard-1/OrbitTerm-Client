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

Run every scenario three times on each idle, plugged-in macOS and iOS device.
Keep all 48 per-run records (2 platforms × 8 scenarios × 3 runs). Use the median
response time, arithmetic mean of the three average CPU values and worst peak
footprint/minimum FPS/hitch count within each platform/scenario group. Do not
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
2. Verify the installed QA bundle, signature and source manifest. For all
   scenarios except `cold_launch`, open that exact app, verify its process on
   the selected device and record its PID privately. A shared `OrbitTerm`
   process name is insufficient when formal and QA apps coexist.
3. Capture CPU and memory with Activity Monitor and explicit Points of Interest:

   ```zsh
   scripts/performance/record_apple_device_slo.sh \
     --scenario terminal_first_frame \
     --device '<device name or UDID>' \
     --pid '<verified positive process ID>' \
     --output performance-evidence/terminal-first-frame-activity.trace
   ```

   For `cold_launch`, verify that the exact candidate is stopped and use
   `--launch '<verified app target supported by xctrace on this device>'`
   instead of `--pid`. Attaching to an already open app cannot measure cold
   launch. Keep its start-to-usable-root observation and signpost attribution;
   a process launch alone does not prove the UI was usable. If launch recording
   returns nonzero, retain that failed attempt and investigate or use a
   separately verified Instruments launch workflow. A saved trace is not a
   successful recording receipt. Use a new output path for every attempt;
   the script refuses existing files, directories and symlinks.

   Give the macOS QA bundle a unique `.app` filename and recheck its signature
   and executable digest after copying it. Instruments can report ambiguity
   even for an absolute path when another bundle has the same filename. Once
   the scenario finishes, quit the verified QA app normally before the recorder
   reaches its time limit. Confirm that the recorded process exited and the
   recorder returned zero. Keep observations with multiple active instances as
   diagnostics and repeat the measurement with a single active QA instance.

4. Repeat the same scenario using `--template 'Animation Hitches'` for frame
   evidence. Read the minimum FPS and hitch count from Instruments; read the
   response interval from the named `com.orbitterm.app / PointsOfInterest` signpost.
5. Summarize each pair of completed Activity Monitor / Animation Hitches traces.
   Supply the exact full lowercase 40-character source commit installed on the
   device, platform (`macos` or `ios`) and run (1–3). For example, replacing the
   illustrative metrics below with actual signpost/frame readings:

   ```zsh
   scripts/performance/summarize_xctrace_activity.py \
     --trace performance-evidence/terminal-first-frame-activity.trace \
     --frame-trace performance-evidence/terminal-first-frame-hitches.trace \
     --scenario terminal_first_frame \
     --build-commit '<full candidate commit>' --platform ios --run 1 \
     --target-pid '<verified Activity Monitor capture process ID>' \
     --response-ms 1200 --minimum-fps 60 --animation-hitches 0 \
     --output performance-evidence/ios-terminal-first-frame-run1.json
   ```

6. Verify all 48 records together against the expected release commit:

   ```zsh
   scripts/performance/verify_apple_device_slo.py \
     --expected-build-commit '<full candidate commit>' performance-evidence/*.json
   ```

Metrics are measurements, never placeholders. Schema v2 requires `kind` =
`apple-device-performance`, `build_commit`, `platform`, `scenario`, `run`, the
five metric fields, positive integer `sample_count`, and both `trace_sha256`
and `frame_trace_sha256`. Version 1 eight-summary inputs are rejected; recollect
or regenerate from the retained real captures with the correct metadata rather
than copying a summary into three runs. Response, FPS and footprint must be
positive; CPU and integer hitch count may be zero. Booleans, non-finite numbers,
negative values, duplicate JSON keys, unknown fields, reused trace digests,
duplicate runs, mixed commits or missing platform/scenario/run groups fail.

The producer requires the Activity Monitor capture's independently verified
PID and rejects rows from another process; that PID is never exported to JSON.
It locates CPU, duration and physical footprint by schema mnemonics, resolves
interned `id`/`ref` values and counts repeated observations. CPU is weighted by
the measured interval duration, without rounding away above-budget readings.
The initial unavailable CPU delta is excluded; unknown columns, broken
references, unsupported/missing intervals or mixed processes fail closed.
Shared/real memory must never substitute for physical footprint. Frame-trace
identity and manual frame/response readings still require private review.

The producer hashes traces incrementally, rejects empty/symlinked packages and
only replaces a summary after export and schema validation succeed. The v2
digest includes relative package entries, their sizes and contents; renaming
the outer trace package does not change its digest. Keep original captures
stable during summarization. The verifier checks structure and stated SLOs;
it cannot prove that manually supplied readings or trace hashes are truthful.

## Release acceptance

The release owner reviews all 48 sanitized per-run records, their trace
hashes, the matching original captures and the build SHA in the private
release-evidence store. The signed release lane enables the fail-closed gate:

```zsh
ORBITTERM_REQUIRE_DEVICE_PERFORMANCE_EVIDENCE=1 \
ORBITTERM_DEVICE_PERFORMANCE_EVIDENCE_DIR=/restricted/evidence/rc-<sha> \
scripts/security/check_apple_release_gates.sh
```

Missing real-device evidence is a release blocker; local Debug and Simulator
measurements can assist diagnosis but do not satisfy this gate.
The release gate supplies its checked-out full commit to the verifier; a
complete matrix from another candidate is rejected. Direct shell validation
requires both the evidence directory and expected commit as arguments to
`scripts/security/check_apple_device_performance_evidence.sh`.
