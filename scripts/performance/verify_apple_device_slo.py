#!/usr/bin/env python3
"""Validate sanitized Apple device performance summaries against release SLOs."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


SLOS = {
    "cold_launch": (3500, 85, 360 * 1024 * 1024, 45, 2),
    "unlock": (2000, 90, 360 * 1024 * 1024, 45, 1),
    "terminal_first_frame": (3500, 75, 420 * 1024 * 1024, 45, 2),
    "terminal_long_output": (250, 80, 440 * 1024 * 1024, 45, 3),
    "docker_log_refresh": (3500, 70, 420 * 1024 * 1024, 45, 2),
    "monitor_refresh": (3500, 70, 420 * 1024 * 1024, 45, 2),
    "sftp_directory_refresh": (3500, 70, 420 * 1024 * 1024, 45, 2),
    "sync_round_trip": (3500, 70, 420 * 1024 * 1024, 45, 2),
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("evidence", type=Path, nargs="+")
    args = parser.parse_args()

    seen: set[str] = set()
    failures: list[str] = []
    for path in args.evidence:
        data = json.loads(path.read_text(encoding="utf-8"))
        scenario = data.get("scenario")
        if scenario not in SLOS:
            failures.append(f"{path}: unknown scenario")
            continue
        seen.add(scenario)
        response, cpu, memory, fps, hitches = SLOS[scenario]
        checks = (
            ("response_milliseconds", data.get("response_milliseconds"), response, "<=", lambda a, b: a <= b),
            ("average_cpu_percent", data.get("average_cpu_percent"), cpu, "<=", lambda a, b: a <= b),
            ("peak_footprint_bytes", data.get("peak_footprint_bytes"), memory, "<=", lambda a, b: a <= b),
            ("minimum_frames_per_second", data.get("minimum_frames_per_second"), fps, ">=", lambda a, b: a >= b),
            ("animation_hitches", data.get("animation_hitches"), hitches, "<=", lambda a, b: a <= b),
        )
        for name, actual, limit, symbol, predicate in checks:
            if not isinstance(actual, (int, float)) or not predicate(actual, limit):
                failures.append(f"{scenario}: {name}={actual!r} must be {symbol} {limit}")

    missing = sorted(set(SLOS).difference(seen))
    if missing:
        failures.append("missing scenarios: " + ", ".join(missing))
    if failures:
        print("Apple device performance SLO evidence failed:", file=sys.stderr)
        print("\n".join(f"- {failure}" for failure in failures), file=sys.stderr)
        return 1
    print(f"Apple device performance SLO evidence passed ({len(seen)} scenarios)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
