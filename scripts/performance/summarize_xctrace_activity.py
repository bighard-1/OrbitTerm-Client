#!/usr/bin/env python3
"""Create a redacted CPU/memory summary from an Activity Monitor trace.

The output intentionally contains only numeric process metrics plus a SHA-256
of the local trace. It never exports terminal bytes, command lines, file paths,
account names, device UDIDs, or remote endpoint data.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path


def values(row: ET.Element, tag: str) -> list[float]:
    result: list[float] = []
    for node in row.iter(tag):
        if node.text:
            try:
                result.append(float(node.text))
            except ValueError:
                pass
    return result


def trace_digest(trace: Path) -> str:
    """Hash an xctrace package without retaining its potentially rich data."""
    digest = hashlib.sha256()
    if trace.is_file():
        digest.update(trace.read_bytes())
        return digest.hexdigest()
    for item in sorted(path for path in trace.rglob("*") if path.is_file()):
        digest.update(str(item.relative_to(trace)).encode("utf-8"))
        digest.update(item.read_bytes())
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--trace", required=True, type=Path)
    parser.add_argument("--scenario", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--response-ms", required=True, type=float)
    parser.add_argument("--minimum-fps", required=True, type=float)
    parser.add_argument("--animation-hitches", required=True, type=int)
    args = parser.parse_args()

    if args.response_ms < 0 or args.minimum_fps < 0 or args.animation_hitches < 0:
        raise SystemExit("performance metrics must be non-negative")
    if not args.trace.exists():
        raise SystemExit(f"trace not found: {args.trace}")

    with tempfile.TemporaryDirectory(prefix="orbitterm-xctrace-") as directory:
        exported = Path(directory) / "activity.xml"
        query = (
            '/trace-toc/run[@number="1"]/data/'
            'table[@schema="activity-monitor-process-live"]'
        )
        subprocess.run(
            [
                "xcrun", "xctrace", "export", "--input", str(args.trace),
                "--xpath", query, "--output", str(exported), "--quiet",
            ],
            check=True,
        )
        root = ET.parse(exported).getroot()

    cpu: list[float] = []
    footprint: list[int] = []
    for row in root.iter("row"):
        cpu.extend(values(row, "system-cpu-percent"))
        footprint.extend(int(value) for value in values(row, "size-in-bytes"))

    # `memory-physical-footprint` is the first size-in-bytes column in the
    # stable Activity Monitor schema. Parse its ordinal explicitly so real,
    # private/shared-memory columns cannot be mistaken for the budget.
    footprint = []
    for row in root.iter("row"):
        children = list(row)
        for index, child in enumerate(children):
            if child.tag == "size-in-bytes" and index >= 10 and child.text:
                try:
                    footprint.append(int(float(child.text)))
                except ValueError:
                    pass
                break

    if not cpu or not footprint:
        raise SystemExit("Activity Monitor trace contains no OrbitTerm CPU or footprint samples")

    payload = {
        "schema_version": 1,
        "scenario": args.scenario,
        "response_milliseconds": args.response_ms,
        "average_cpu_percent": round(sum(cpu) / len(cpu), 3),
        "peak_footprint_bytes": max(footprint),
        "minimum_frames_per_second": args.minimum_fps,
        "animation_hitches": args.animation_hitches,
        "trace_sha256": trace_digest(args.trace),
        "sample_count": len(cpu),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
