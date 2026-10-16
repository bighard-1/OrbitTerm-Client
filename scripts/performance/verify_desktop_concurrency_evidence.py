#!/usr/bin/env python3
"""Validate sanitized evidence for the desktop transfer/concurrency release blocker."""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path


SCENARIO = "three-assets-six-panes-3-gib-transfer"
PLATFORMS = {"windows-10", "windows-11", "macos"}
RUNS_PER_PLATFORM = 3
MAX_CLICK_RESPONSE_MS = 250
MAX_SESSION_SWITCH_MS = 500
MAX_PROGRESS_UPDATES_PER_SECOND = 8
MAX_CANCELING_STATE_MS = 1000
MAX_MEMORY_GROWTH_BYTES = 64 * 1024 * 1024
MIN_LATE_THROUGHPUT_RATIO = 0.70
FORBIDDEN_KEYS = {
    "account", "endpoint", "host", "path", "command", "terminal_output",
    "credential", "token", "private_key", "device_udid",
}
COMMIT_PATTERN = re.compile(r"^[0-9a-f]{7,64}$")


def fail(message: str) -> None:
    raise ValueError(message)


def number(record: dict[str, object], key: str, minimum: float | None = None, maximum: float | None = None) -> None:
    value = record.get(key)
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        fail(f"{key} must be numeric")
    if minimum is not None and value < minimum:
        fail(f"{key}={value} must be >= {minimum}")
    if maximum is not None and value > maximum:
        fail(f"{key}={value} must be <= {maximum}")


def validate_record(path: Path) -> tuple[str, int]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        fail(f"{path}: expected an object")
    leaked = sorted(FORBIDDEN_KEYS.intersection(data))
    if leaked:
        fail(f"{path}: forbidden evidence fields: {', '.join(leaked)}")
    if data.get("schema_version") != 1:
        fail(f"{path}: unsupported schema_version")
    if data.get("kind") != "desktop-concurrency":
        fail(f"{path}: unexpected evidence kind")
    if data.get("scenario") != SCENARIO:
        fail(f"{path}: unexpected scenario")
    platform = data.get("platform")
    if platform not in PLATFORMS:
        fail(f"{path}: unsupported platform {platform!r}")
    run = data.get("run")
    if not isinstance(run, int) or isinstance(run, bool) or run not in range(1, RUNS_PER_PLATFORM + 1):
        fail(f"{path}: run must be an integer from 1 to {RUNS_PER_PLATFORM}")
    build_commit = data.get("build_commit")
    if not isinstance(build_commit, str) or not COMMIT_PATTERN.fullmatch(build_commit):
        fail(f"{path}: build_commit must be a lowercase Git SHA")

    number(data, "duration_seconds", minimum=900)
    number(data, "max_click_response_ms", maximum=MAX_CLICK_RESPONSE_MS)
    number(data, "max_session_switch_ms", maximum=MAX_SESSION_SWITCH_MS)
    number(data, "blank_pane_count", minimum=0, maximum=0)
    number(data, "stale_monitor_intervals", minimum=0, maximum=0)
    number(data, "max_ui_progress_updates_per_second", minimum=0, maximum=MAX_PROGRESS_UPDATES_PER_SECOND)
    number(data, "canceling_state_ms", minimum=0, maximum=MAX_CANCELING_STATE_MS)
    number(data, "memory_start_bytes", minimum=0)
    number(data, "memory_end_bytes", minimum=0)
    memory_growth = data["memory_end_bytes"] - data["memory_start_bytes"]
    if memory_growth > MAX_MEMORY_GROWTH_BYTES:
        fail(f"{path}: memory growth {memory_growth} exceeds {MAX_MEMORY_GROWTH_BYTES} bytes")
    number(data, "late_window_throughput_ratio", minimum=MIN_LATE_THROUGHPUT_RATIO, maximum=1)
    return platform, run


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path, nargs="+", help="Sanitized JSON evidence files")
    args = parser.parse_args()
    observed: dict[str, set[int]] = defaultdict(set)
    failures: list[str] = []
    for path in args.evidence:
        try:
            platform, run = validate_record(path)
            if run in observed[platform]:
                fail(f"{path}: duplicate {platform} run {run}")
            observed[platform].add(run)
        except (OSError, ValueError, json.JSONDecodeError) as error:
            failures.append(str(error))
    for platform in sorted(PLATFORMS):
        missing = sorted(set(range(1, RUNS_PER_PLATFORM + 1)).difference(observed[platform]))
        if missing:
            failures.append(f"{platform}: missing runs {', '.join(map(str, missing))}")
    if failures:
        print("Desktop concurrency evidence failed:", file=sys.stderr)
        print("\n".join(f"- {failure}" for failure in failures), file=sys.stderr)
        return 1
    print(f"Desktop concurrency evidence passed ({len(PLATFORMS) * RUNS_PER_PLATFORM} sanitized runs)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
