#!/usr/bin/env python3
"""Validate the desktop stabilization freeze and its machine-readable scope."""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
GATE = ROOT / "docs" / "release" / "DESKTOP_STABILIZATION_GATE.json"
BASELINE = ROOT / "docs" / "DESKTOP_STABILIZATION_BASELINE.md"
MATRIX = ROOT / "docs" / "WINDOWS_MACOS_WORKSTATION_PARITY.md"
DEBT = ROOT / "docs" / "TECHNICAL_DEBT.md"
REAL_DEVICE_PREFLIGHT = ROOT / "scripts" / "performance" / "preflight_real_device_acceptance.sh"

REQUIRED_DOMAINS = {
    "terminal", "multi-session", "split-pane", "sftp", "docker",
    "monitoring", "snippets", "batch-command", "account-unlock",
    "encrypted-sync", "themes", "shortcuts",
}
REQUIRED_P0 = {
    "cross-platform-asset-tombstones",
    "large-transfer-interactive-concurrency",
}
ALLOWED_STATUSES = {"not-started", "in-progress", "blocked", "complete"}
EXPECTED_TOMBSTONE_PLATFORMS = {"windows", "macos", "ios", "android"}
EXPECTED_TOMBSTONE_SCENARIOS = {
    "delete_then_pull",
    "delete_after_edit",
    "offline_delete_then_reconnect",
    "repeat_sync_no_resurrection",
}
EXPECTED_CONCURRENCY_PLATFORMS = {"windows-10", "windows-11", "macos"}
CONCURRENCY_SCENARIO = "three-assets-six-panes-3-gib-transfer"


def fail(message: str) -> None:
    raise SystemExit(f"desktop stabilization gate failed: {message}")


def require_string_list(value: object, label: str) -> set[str]:
    if not isinstance(value, list) or not value or not all(isinstance(item, str) and item for item in value):
        fail(f"{label} must be a non-empty string list")
    return set(value)


def validate_evidence_contract(data: dict[str, object]) -> None:
    contract = data.get("evidence_contract")
    if not isinstance(contract, dict):
        fail("missing evidence_contract")
    if contract.get("manifest_schema_version") != 1:
        fail("unsupported evidence manifest schema")
    if contract.get("storage") != "restricted-release-evidence-store":
        fail("release evidence must remain in the restricted evidence store")
    forbidden = require_string_list(contract.get("forbidden_fields"), "evidence_contract.forbidden_fields")
    required = require_string_list(contract.get("required_metadata"), "evidence_contract.required_metadata")
    if not {"credential", "token", "private_key", "terminal_output"}.issubset(forbidden):
        fail("evidence contract must prohibit credential, token, private key, and terminal output")
    if not {"build_commit", "platform", "scenario", "run"}.issubset(required):
        fail("evidence contract must require build_commit, platform, scenario, and run")


def validate_blocker_evidence(blockers: list[object]) -> None:
    by_id = {item.get("id"): item for item in blockers if isinstance(item, dict)}

    tombstone = by_id.get("cross-platform-asset-tombstones")
    if not isinstance(tombstone, dict) or not isinstance(tombstone.get("evidence_plan"), dict):
        fail("tombstone blocker is missing its evidence plan")
    tombstone_plan = tombstone["evidence_plan"]
    if require_string_list(tombstone_plan.get("required_platforms"), "tombstone required_platforms") != EXPECTED_TOMBSTONE_PLATFORMS:
        fail("tombstone evidence plan must cover Windows, macOS, iOS, and Android")
    if require_string_list(tombstone_plan.get("required_scenarios"), "tombstone required_scenarios") != EXPECTED_TOMBSTONE_SCENARIOS:
        fail("tombstone evidence plan is missing a required deletion scenario")
    if tombstone_plan.get("minimum_completed_matrix_runs") != 1:
        fail("tombstone evidence plan must require one completed four-platform matrix")

    concurrency = by_id.get("large-transfer-interactive-concurrency")
    if not isinstance(concurrency, dict) or not isinstance(concurrency.get("evidence_plan"), dict):
        fail("concurrency blocker is missing its evidence plan")
    concurrency_plan = concurrency["evidence_plan"]
    if require_string_list(concurrency_plan.get("required_platforms"), "concurrency required_platforms") != EXPECTED_CONCURRENCY_PLATFORMS:
        fail("concurrency evidence plan must cover Windows 10, Windows 11, and macOS")
    if concurrency_plan.get("scenario") != CONCURRENCY_SCENARIO:
        fail("concurrency evidence plan has an unexpected scenario")
    if concurrency_plan.get("runs_per_platform") != 3:
        fail("concurrency evidence plan must require three runs per platform")
    if concurrency_plan.get("minimum_duration_seconds") != 900:
        fail("concurrency evidence plan must require a fifteen-minute run")


def main() -> int:
    for path in (GATE, BASELINE, MATRIX, DEBT, REAL_DEVICE_PREFLIGHT):
        if not path.is_file():
            fail(f"missing {path.relative_to(ROOT)}")

    data = json.loads(GATE.read_text(encoding="utf-8"))
    if data.get("schema_version") != 2:
        fail("unsupported schema_version")
    if data.get("new_feature_freeze") is not True:
        fail("new feature freeze must remain enabled while P0 blockers are open")

    domains = set(data.get("required_domains", []))
    missing_domains = sorted(REQUIRED_DOMAINS - domains)
    if missing_domains:
        fail("missing required domains: " + ", ".join(missing_domains))

    blockers = data.get("p0_blockers", [])
    blocker_ids = {item.get("id") for item in blockers}
    missing_blockers = sorted(REQUIRED_P0 - blocker_ids)
    if missing_blockers:
        fail("missing P0 blockers: " + ", ".join(missing_blockers))
    for blocker in blockers:
        if blocker.get("status") not in ALLOWED_STATUSES:
            fail(f"invalid status for {blocker.get('id')}")
        if not blocker.get("owner_scope") or not blocker.get("exit_criteria"):
            fail(f"incomplete ownership or exit criteria for {blocker.get('id')}")
    validate_evidence_contract(data)
    validate_blocker_evidence(blockers)

    baseline = BASELINE.read_text(encoding="utf-8")
    if (
        "冻结非必要新功能" not in baseline
        or "三台资产" not in baseline
        or "六路长输出" not in baseline
        or "15 分钟" not in baseline
    ):
        fail("human-readable baseline is missing freeze or stress-scenario language")

    protocol = (ROOT / "docs" / "release" / "REAL_DEVICE_ACCEPTANCE_PROTOCOL.md").read_text(encoding="utf-8")
    if "preflight_real_device_acceptance.sh" not in protocol:
        fail("real-device protocol must require the acceptance preflight")

    print(
        "Desktop stabilization baseline passed "
        f"({len(domains)} domains, {len(blockers)} P0 blockers)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
