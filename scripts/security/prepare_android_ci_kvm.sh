#!/usr/bin/env bash
set -euo pipefail

# This changes only the current ephemeral GitHub runner's device ACL. Never
# install a world-writable udev rule or modify a developer machine implicitly.
[[ "${GITHUB_ACTIONS:-}" == true && "$(uname -s)" == Linux ]] || {
  echo '[FAIL] KVM setup is restricted to the Linux GitHub runner' >&2
  exit 1
}
[[ -c /dev/kvm ]] || {
  echo '[FAIL] /dev/kvm is missing; this runner cannot host the accelerated Android gate' >&2
  exit 1
}
if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
  command -v setfacl >/dev/null || {
    echo '[FAIL] setfacl is required to grant only this runner access to KVM' >&2
    exit 1
  }
  sudo -n setfacl -m "u:$(id -u):rw" /dev/kvm
fi
python3 - <<'PY'
import os

fd = os.open('/dev/kvm', os.O_RDWR | os.O_CLOEXEC)
os.close(fd)
print('[PASS] Current runner can open KVM; software CPU fallback is not permitted')
PY
