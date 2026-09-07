#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
linux_root="$(cd "$script_dir/.." && pwd)"

source "$HOME/.cargo/env" 2>/dev/null || true

cargo fmt --manifest-path "$linux_root/Cargo.toml" --all -- --check
cargo clippy --locked --manifest-path "$linux_root/Cargo.toml" --workspace --all-targets -- -D warnings
cargo test --locked --manifest-path "$linux_root/Cargo.toml" --workspace

if rg -n \
    'orbit_(test_ssh_connection|ssh_connect|sftp_connect|request_channel|sftp_list_dir|exec_command)\s*\(' \
    "$linux_root/crates" \
    --glob '*.rs'; then
    echo "检测到 Linux production code 调用 legacy 网络 ABI。" >&2
    exit 1
fi

desktop-file-validate "$linux_root/data/com.orbitterm.Client.desktop"
if command -v appstreamcli >/dev/null 2>&1; then
    appstreamcli validate --no-net "$linux_root/data/com.orbitterm.Client.metainfo.xml"
fi
