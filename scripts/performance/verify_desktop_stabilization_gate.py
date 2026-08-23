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


def fail(message: str) -> None:
    raise SystemExit(f"desktop stabilization gate failed: {message}")


def main() -> int:
    for path in (GATE, BASELINE, MATRIX, DEBT):
        if not path.is_file():
            fail(f"missing {path.relative_to(ROOT)}")

    data = json.loads(GATE.read_text(encoding="utf-8"))
    if data.get("schema_version") != 1:
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

    baseline = BASELINE.read_text(encoding="utf-8")
    if "冻结非必要新功能" not in baseline or "三台资产" not in baseline:
        fail("human-readable baseline is missing freeze or stress-scenario language")

    print(
        "Desktop stabilization baseline passed "
        f"({len(domains)} domains, {len(blockers)} P0 blockers)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

