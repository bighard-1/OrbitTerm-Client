#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EVIDENCE_DIR="${1:?usage: check_apple_device_performance_evidence.sh <evidence-directory>}"

[[ -d "$EVIDENCE_DIR" ]] || { echo "missing device performance evidence directory" >&2; exit 1; }

shopt -s nullglob
evidence=("$EVIDENCE_DIR"/*.json)
(( ${#evidence[@]} > 0 )) || { echo "no sanitized performance evidence JSON files found" >&2; exit 1; }

exec python3 "$ROOT/scripts/performance/verify_apple_device_slo.py" "${evidence[@]}"
