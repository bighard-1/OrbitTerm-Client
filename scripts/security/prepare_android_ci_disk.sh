#!/usr/bin/env bash
set -euo pipefail

# Only this disposable hosted Android job may remove unused preinstalled SDKs.
# Never clean a developer machine or a persistent self-hosted runner.
[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted &&
   "$(uname -s)" == Linux ]] || {
  echo '[FAIL] Android disk preparation requires a disposable Linux GitHub-hosted runner' >&2
  exit 1
}

mode="${1:-}"
[[ $# == 1 && ( "$mode" == --cleanup || "$mode" == --verify ) ]] || {
  echo '[FAIL] Expected --cleanup or --verify' >&2
  exit 1
}
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
report="$root/clients/android/OrbitTermAndroid/build/qa-instrumentation/disk.jsonl"

record_disk() {
  python3 - "$report" "$1" <<'PY'
import json
import os
from pathlib import Path
import shutil
import sys

report, phase = Path(sys.argv[1]), sys.argv[2]
avd = Path(os.environ.get("ANDROID_AVD_HOME", str(Path.home() / ".android/avd")))
probe = avd
while not probe.exists():
    probe = probe.parent
free = shutil.disk_usage(probe).free
entry = {"phase": phase, "free_bytes": free, "required_bytes": 10 * 1024**3}
report.parent.mkdir(parents=True, exist_ok=True)
with report.open("a") as output:
    output.write(json.dumps(entry) + "\n")
print(f"Android emulator disk ({phase}): {free // (1024**2)} MiB free", flush=True)
if phase == "before-emulator" and free < entry["required_bytes"]:
    sys.exit("[FAIL] Android emulator needs 10 GiB free after prebuild and image installation")
PY
}

if [[ "$mode" == --cleanup ]]; then
  record_disk before-cleanup
  # This job uses Java, Rust and Android only; keep their SDKs, build caches,
  # native outputs, test APKs and reports intact.
  sudo -n rm -rf -- /usr/share/dotnet /usr/local/.ghcup /opt/ghc
  record_disk after-cleanup
else
  record_disk before-emulator
  "${ANDROID_HOME:?Android SDK is required}/emulator/emulator" -accel-check
fi
