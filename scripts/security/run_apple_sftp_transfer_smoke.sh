#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture_python="${ORBITTERM_APPLE_SFTP_PYTHON:-python3}"
fixture_parent="${ORBITTERM_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
derived_data="${ORBITTERM_APPLE_SFTP_DERIVED_DATA:-${fixture_parent}/orbitterm-apple-sftp-derived}"

"$fixture_python" -c 'import asyncssh' || {
  echo 'Set ORBITTERM_APPLE_SFTP_PYTHON to a Python runtime with AsyncSSH.' >&2
  exit 1
}
fixture_root="$(mktemp -d "${fixture_parent%/}/orbitterm-apple-sftp.XXXXXX")"
fixture_pid=''
cleanup() {
  if [[ -n "$fixture_pid" ]]; then
    kill "$fixture_pid" 2>/dev/null || true
    wait "$fixture_pid" 2>/dev/null || true
  fi
  rm -rf -- "$fixture_root"
}
trap cleanup EXIT
chmod 700 "$fixture_root"
"$fixture_python" "${repo_root}/scripts/security/apple_sftp_transfer_fixture.py" "$fixture_root" &
fixture_pid=$!
for _ in {1..100}; do
  [[ -f "${fixture_root}/config.json" ]] && break
  kill -0 "$fixture_pid" 2>/dev/null || exit 1
  sleep 0.1
done
test -f "${fixture_root}/config.json"

(
  cd "${repo_root}/orbit-core"
  MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --locked --target aarch64-apple-darwin
)
TEST_RUNNER_ORBITTERM_SFTP_FIXTURE_CONFIG="${fixture_root}/config.json" \
  xcodebuild test -quiet -project "${repo_root}/OrbitTerm.xcodeproj" \
  -scheme OrbitTermCheckedFFITests -destination 'platform=macOS' \
  -derivedDataPath "$derived_data" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OrbitTermCheckedFFITests/CheckedSFTPServiceTests/testLoopbackCheckedTransferPreservesExistingTargetsAndCancelsOwnedTarget
