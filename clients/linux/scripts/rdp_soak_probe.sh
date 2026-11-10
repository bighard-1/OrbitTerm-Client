#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s --pid PID [--duration-seconds N] [--interval-seconds N] [--output PATH]\n' "$0"
}

pid=""
duration_seconds=3600
interval_seconds=30
output=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pid)
      pid="${2:-}"
      shift 2
      ;;
    --duration-seconds)
      duration_seconds="${2:-}"
      shift 2
      ;;
    --interval-seconds)
      interval_seconds="${2:-}"
      shift 2
      ;;
    --output)
      output="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! "$pid" =~ ^[1-9][0-9]*$ ]] ||
   [[ ! "$duration_seconds" =~ ^[1-9][0-9]*$ ]] ||
   [[ ! "$interval_seconds" =~ ^[1-9][0-9]*$ ]] ||
   (( duration_seconds > 21600 )) || (( interval_seconds > duration_seconds )); then
  usage >&2
  exit 2
fi

if [[ -z "$output" ]]; then
  output="rdp-soak-${pid}-$(date -u +%Y%m%dT%H%M%SZ).tsv"
fi

if [[ ! -r "/proc/$pid/status" ]]; then
  printf 'Process %s is not readable.\n' "$pid" >&2
  exit 3
fi

printf 'utc\telapsed_s\trss_kib\tcpu_percent\tthreads\tfds\n' > "$output"
started=$SECONDS
samples=0
min_rss=""
max_rss=0

while (( SECONDS - started <= duration_seconds )); do
  if [[ ! -r "/proc/$pid/status" ]]; then
    printf 'Process %s exited before the soak completed.\n' "$pid" >&2
    exit 4
  fi
  rss=$(awk '/^VmRSS:/ { print $2 }' "/proc/$pid/status")
  threads=$(awk '/^Threads:/ { print $2 }' "/proc/$pid/status")
  cpu=$(ps -p "$pid" -o %cpu= | tr -d ' ')
  fds=$(find "/proc/$pid/fd" -mindepth 1 -maxdepth 1 -printf '.' 2>/dev/null | wc -c)
  elapsed=$((SECONDS - started))
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$elapsed" "$rss" "${cpu:-0}" "$threads" "$fds" >> "$output"
  samples=$((samples + 1))
  if [[ -z "$min_rss" ]] || (( rss < min_rss )); then min_rss=$rss; fi
  if (( rss > max_rss )); then max_rss=$rss; fi
  if (( elapsed >= duration_seconds )); then break; fi
  sleep "$interval_seconds"
done

printf 'SUMMARY\tsamples=%s\tmin_rss_kib=%s\tmax_rss_kib=%s\tdelta_rss_kib=%s\n' \
  "$samples" "$min_rss" "$max_rss" "$((max_rss - min_rss))" >> "$output"
printf '%s\n' "$output"
