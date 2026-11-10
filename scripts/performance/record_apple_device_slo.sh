#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
usage: record_apple_device_slo.sh --scenario <name> --device <name-or-udid> --output <new-trace-path> (--pid <positive-pid> | --launch <app-or-executable>) [--duration 75s] [--template 'Activity Monitor'|'Animation Hitches']

Use --launch only for cold_launch, after verifying the exact signed candidate
is not running. For other scenarios verify the candidate process on the
selected device and pass its PID; ambiguous process-name attachment is refused.
Start this recorder, then execute only the named scenario. Raw traces stay in
the private evidence store, outside source control and support diagnostics.
EOF
}

scenario=""
device=""
output=""
duration="75s"
template="Activity Monitor"
target_pid=""
launch=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario|--device|--output|--duration|--template|--pid|--launch)
      [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { usage >&2; exit 2; }
      case "$1" in
        --scenario) scenario="$2" ;;
        --device) device="$2" ;;
        --output) output="$2" ;;
        --duration) duration="$2" ;;
        --template) template="$2" ;;
        --pid) target_pid="$2" ;;
        --launch) launch="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

case "$scenario" in
  cold_launch|unlock|terminal_first_frame|terminal_long_output|docker_log_refresh|monitor_refresh|sftp_directory_refresh|sync_round_trip) ;;
  *) echo "Unsupported performance scenario." >&2; exit 2 ;;
esac

[[ -n "$device" && -n "$output" ]] || { usage >&2; exit 2; }
[[ "$duration" =~ ^[1-9][0-9]{0,2}s$ ]] || { usage >&2; exit 2; }
case "$template" in
  'Activity Monitor'|'Animation Hitches') ;;
  *) usage >&2; exit 2 ;;
esac
target=()
if [[ "$scenario" == cold_launch ]]; then
  [[ -n "$launch" && -z "$target_pid" ]] || { usage >&2; exit 2; }
  target=(--launch -- "$launch")
else
  [[ "$target_pid" =~ ^[1-9][0-9]*$ && -z "$launch" ]] || { usage >&2; exit 2; }
  target=(--attach "$target_pid")
fi
[[ ! -e "$output" && ! -L "$output" ]] || {
  echo "Capture output already exists; refusing to append or overwrite." >&2; exit 2;
}
mkdir -p "$(dirname "$output")"

# Use a verified PID or explicit cold-launch target, never a shared app name.
# Add Points of Interest explicitly: the stock Activity Monitor template need
# not collect the application's response-boundary signposts on its own.
exec xcrun xctrace record \
  --template "$template" \
  --instrument 'Points of Interest' \
  --device "$device" \
  --time-limit "$duration" \
  --output "$output" \
  --notify-tracing-started com.orbitterm.performance.trace.ready \
  --no-prompt \
  "${target[@]}"
