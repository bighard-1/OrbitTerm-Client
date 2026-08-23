#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
usage: record_apple_device_slo.sh --scenario <name> --device <name-or-udid> --output <trace-path> [--duration 75s] [--template 'Activity Monitor']

The target OrbitTerm app must already be open on the selected device. Start
this recorder, then execute only the named scenario. The recorder stores an
Instruments trace locally; do not commit or attach it to support diagnostics.
EOF
}

scenario=""
device=""
output=""
duration="75s"
template="Activity Monitor"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario) scenario="$2"; shift 2 ;;
    --device) device="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --duration) duration="$2"; shift 2 ;;
    --template) template="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

case "$scenario" in
  cold_launch|unlock|terminal_first_frame|terminal_long_output|docker_log_refresh|monitor_refresh|sftp_directory_refresh|sync_round_trip) ;;
  *) echo "unsupported scenario: $scenario" >&2; exit 2 ;;
esac

[[ -n "$device" && -n "$output" ]] || { usage >&2; exit 2; }
mkdir -p "$(dirname "$output")"

# The attach target is the app process name, not a user, host, command, path,
# or terminal payload. Activity Monitor records CPU/footprint; run a second
# capture with the Animation Hitches template for FPS/hitch evidence.
exec xcrun xctrace record \
  --template "$template" \
  --device "$device" \
  --attach OrbitTerm \
  --time-limit "$duration" \
  --output "$output" \
  --notify-tracing-started com.orbitterm.performance.trace.ready \
  --no-prompt
