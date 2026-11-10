#!/usr/bin/env bash

# Source archives are promoted into the cache only after a successful transfer
# and the caller's pinned digest. Never execute or extract a partial download.
download_and_verify() (
  set -euo pipefail
  local url="$1" expected="$2" output="$3" fallback="${4:-$1}"
  if [[ ! "$expected" =~ ^[0-9a-f]{64}$ || "$url" != https://* || "$fallback" != https://* ]]; then
    printf 'Expected a pinned SHA-256 and HTTPS source URLs.\n' >&2
    exit 1
  fi
  local actual
  if [[ -f "$output" ]]; then
    actual="$(shasum -a 256 "$output" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || {
      printf 'Checksum mismatch in existing source cache: %s\n' "$output" >&2
      exit 1
    }
    return 0
  fi

  mkdir -p "$(dirname "$output")"
  local temporary attempt status=1
  temporary="$(mktemp "${output}.partial.XXXXXX")"
  # EXIT runs after function-local variables unwind on some Bash versions.
  # Quote the path now so cleanup also preserves the original failure status.
  trap "$(printf 'rm -f -- %q' "$temporary")" EXIT
  for attempt in 1 2 3; do
    # Reset the partial file even after a failed transfer wrote some bytes.
    : > "$temporary"
    if curl --disable --fail --location --silent --show-error \
      --proto '=https' --proto-redir '=https' \
      --connect-timeout 15 --max-time 120 --retry 0 \
      --output "$temporary" "$url"; then
      actual="$(shasum -a 256 "$temporary" | awk '{print $1}')"
      [[ "$actual" == "$expected" ]] || {
        printf 'Checksum mismatch for downloaded source: %s\n' "$output" >&2
        exit 1
      }
      mv -f "$temporary" "$output"
      return 0
    else
      status=$?
    fi
    printf 'Source download attempt %s/3 failed (curl %s).\n' "$attempt" "$status" >&2
    if [[ "$attempt" -lt 3 ]]; then
      url="$fallback"
      sleep 2
    fi
  done
  exit "$status"
)
