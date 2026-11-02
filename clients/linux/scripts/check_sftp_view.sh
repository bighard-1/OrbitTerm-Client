#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
linux_root="$(cd "$script_dir/.." && pwd)"
source "$HOME/.cargo/env" 2>/dev/null || true

for required in cargo dbus-run-session xvfb-run rg; do
  command -v "$required" >/dev/null 2>&1 || {
    echo "Missing required SFTP view gate tool: $required" >&2
    exit 1
  }
done

log="$(mktemp "${TMPDIR:-/tmp}/orbitterm-sftp-view.XXXXXX")"
trap 'rm -f "$log"' EXIT
GTK_A11Y=none GSETTINGS_BACKEND=memory dbus-run-session -- \
  xvfb-run --auto-servernum --server-args="-screen 0 1280x800x24 -nolisten tcp" \
  cargo test --locked --manifest-path "$linux_root/Cargo.toml" --package orbitterm-linux \
    ui::tests::sftp_directory_widgets_discard_old_rows_and_block_actions -- \
    --ignored --exact --test-threads=1 --color never 2>&1 | tee "$log"

# A typo in the filter must not turn this display-dependent gate into a zero-test pass.
if ! rg -q '^test result: ok\. 1 passed; 0 failed;' "$log"; then
  echo "The GTK SFTP view test did not execute successfully." >&2
  exit 1
fi
echo "[PASS] GTK SFTP view clears stale rows and blocks unvalidated actions"
