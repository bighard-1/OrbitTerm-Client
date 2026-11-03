#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
linux_root="$(cd "$script_dir/.." && pwd)"

source "$HOME/.cargo/env" 2>/dev/null || true
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --print-binary-path ) ]]; then
    echo "Usage: build_release.sh [--print-binary-path]" >&2
    exit 2
fi

# Cargo's artifact is authoritative: caches and target triples can move it
# away from target/release. Never package a binary left at the default path.
artifact_log="$(mktemp "${TMPDIR:-/tmp}/orbitterm-release.XXXXXX")"
trap 'rm -f "$artifact_log"' EXIT
if ! cargo build --locked --release --manifest-path "$linux_root/Cargo.toml" \
    --package orbitterm-linux --message-format=json-render-diagnostics >"$artifact_log"; then
    cat "$artifact_log" >&2
    exit 1
fi
binary="$(python3 - "$artifact_log" <<'PY'
import json
import sys

paths = set()
with open(sys.argv[1], encoding="utf-8") as messages:
    for line in messages:
        message = json.loads(line)
        target = message.get("target", {})
        if (message.get("reason") == "compiler-artifact"
                and target.get("name") == "orbitterm-linux"
                and "bin" in target.get("kind", [])
                and message.get("executable")):
            paths.add(message["executable"])
if len(paths) != 1:
    sys.exit("Expected exactly one OrbitTerm release executable from Cargo.")
print(paths.pop())
PY
)"
test -x "$binary"
if [[ "${1:-}" == --print-binary-path ]]; then
    printf '%s\n' "$binary"
    exit 0
fi
file "$binary"
