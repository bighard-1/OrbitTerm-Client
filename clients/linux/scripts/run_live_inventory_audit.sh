#!/usr/bin/env bash
set -euo pipefail

source "$HOME/.cargo/env" 2>/dev/null || true

required=(
  ORBITTERM_TEST_USERNAME
  ORBITTERM_TEST_PASSWORD
  ORBITTERM_TEST_MASTER_PASSWORD
)

if [[ "${ORBITTERM_SYNC_MATRIX_SCOPE:-}" != "isolated-test-account" ]]; then
  echo "Refusing to run: set ORBITTERM_SYNC_MATRIX_SCOPE=isolated-test-account for a dedicated test account." >&2
  exit 2
fi

for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: ${name}" >&2
    exit 2
  fi
done

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
linux_root="$(cd -- "${script_dir}/.." && pwd)"
evidence_dir="${ORBITTERM_SYNC_EVIDENCE_DIR:-${linux_root}/evidence}"
umask 077
mkdir -p "${evidence_dir}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
temporary_report="$(mktemp "${evidence_dir}/.live-inventory-audit-${timestamp}.XXXXXX")"
report="${evidence_dir}/live-inventory-audit-${timestamp}.txt"
trap 'rm -f "${temporary_report}"' EXIT
cd "${linux_root}"
{
  echo "OrbitTerm Isolated Account Inventory Audit v1"
  echo "generated_utc=${timestamp}"
  echo "platform=$(uname -srm)"
  echo "rust=$(rustc --version)"
  cargo test -p orbit-linux-sync --test live_inventory_audit -- --ignored --exact isolated_account_inventory_is_decryptable_without_mutation --nocapture
} >"${temporary_report}" 2>&1
mv "${temporary_report}" "${report}"
chmod 600 "${report}"
trap - EXIT
echo "Evidence: ${report}"
sha256sum "${report}"
