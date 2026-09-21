#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
linux_root="$(cd "$script_dir/.." && pwd)"

source "$HOME/.cargo/env" 2>/dev/null || true
exec cargo run --locked --manifest-path "$linux_root/Cargo.toml" --package orbitterm-linux
