#!/usr/bin/env python3
"""Create a redacted CPU/memory summary from an Activity Monitor trace.

The output intentionally contains only numeric process metrics plus a SHA-256
of the local trace. It never exports terminal bytes, command lines, file paths,
account names, device UDIDs, or remote endpoint data.
"""

from __future__ import annotations

import hashlib
import json
import math
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

from evidence_validation import EvidenceArgumentParser, expected_commit, reject
from verify_apple_device_slo import PLATFORMS, SLOS, validate_record


def values(row: ET.Element, tag: str) -> list[float]:
    result: list[float] = []
    for node in row.iter(tag):
        if node.text:
            try:
                result.append(float(node.text))
            except ValueError:
                reject('trace contains a malformed numeric sample')
    if any(not math.isfinite(value) or value < 0 for value in result):
        reject('trace contains a non-finite or negative numeric sample')
    return result


def trace_digest(trace: Path) -> str:
    """Hash an xctrace package without retaining its potentially rich data."""
    digest = hashlib.sha256()
    if trace.is_symlink():
        reject('trace package must not be a symlink')
    items = [trace] if trace.is_file() else sorted(trace.rglob('*'))
    measured_files = 0
    measured_bytes = 0
    for item in items:
        if item.is_symlink():
            reject('trace package must not contain symlinks')
        if not item.is_file():
            continue
        measured_files += 1
        measured_bytes += item.stat().st_size
        relative = '' if trace.is_file() else str(item.relative_to(trace))
        digest.update(relative.encode('utf-8') + b'\0')
        digest.update(str(item.stat().st_size).encode('ascii') + b'\0')
        with item.open('rb') as stream:
            while block := stream.read(1024 * 1024):
                digest.update(block)
    if measured_files == 0 or measured_bytes == 0:
        reject('trace package contains no capture data')
    return digest.hexdigest()


def main() -> int:
    parser = EvidenceArgumentParser()
    parser.add_argument("--trace", required=True, type=Path)
    parser.add_argument("--frame-trace", required=True, type=Path)
    parser.add_argument("--scenario", required=True, choices=sorted(SLOS))
    parser.add_argument("--build-commit", required=True)
    parser.add_argument("--platform", required=True, choices=sorted(PLATFORMS))
    parser.add_argument("--run", required=True, type=int, choices=(1, 2, 3))
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--response-ms", required=True, type=float)
    parser.add_argument("--minimum-fps", required=True, type=float)
    parser.add_argument("--animation-hitches", required=True, type=int)
    args = parser.parse_args()

    candidate = expected_commit(args.build_commit)
    if (not math.isfinite(args.response_ms) or args.response_ms <= 0 or
            not math.isfinite(args.minimum_fps) or args.minimum_fps <= 0 or
            args.animation_hitches < 0):
        reject('response/FPS must be positive and finite; hitch count must be non-negative')
    if not args.trace.exists() or not args.frame_trace.exists():
        reject('required Activity Monitor or frame trace is missing')
    activity_digest = trace_digest(args.trace)
    frame_digest = trace_digest(args.frame_trace)
    if activity_digest == frame_digest:
        reject('Activity Monitor and frame captures must be distinct')

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
            capture_output=True,
        )
        root = ET.parse(exported).getroot()

    cpu: list[float] = []
    footprint: list[int] = []
    for row in root.iter("row"):
        cpu.extend(values(row, "system-cpu-percent"))

    # `memory-physical-footprint` is the first size-in-bytes column in the
    # stable Activity Monitor schema. Parse its ordinal explicitly so real,
    # private/shared-memory columns cannot be mistaken for the budget.
    for row in root.iter("row"):
        children = list(row)
        for index, child in enumerate(children):
            if child.tag == "size-in-bytes" and index >= 10 and child.text:
                try:
                    sample = float(child.text)
                except (ValueError, OverflowError):
                    reject('trace contains a malformed footprint sample')
                if not math.isfinite(sample) or not sample.is_integer() or sample <= 0:
                    reject('trace footprint sample must be positive, finite integer bytes')
                footprint.append(int(sample))
                break

    if not cpu or not footprint:
        reject('Activity Monitor trace contains no CPU or footprint samples')

    payload = {
        "schema_version": 2,
        "kind": "apple-device-performance",
        "build_commit": candidate,
        "platform": args.platform,
        "scenario": args.scenario,
        "run": args.run,
        "response_milliseconds": args.response_ms,
        "average_cpu_percent": round(sum(cpu) / len(cpu), 3),
        "peak_footprint_bytes": max(footprint),
        "minimum_frames_per_second": args.minimum_fps,
        "animation_hitches": args.animation_hitches,
        "trace_sha256": activity_digest,
        "frame_trace_sha256": frame_digest,
        "sample_count": len(cpu),
    }
    # Check the exact consumer contract before promoting a summary. A failed
    # export or validation must not truncate a prior summary.
    with tempfile.TemporaryDirectory(prefix='orbitterm-summary-check-') as directory:
        provisional = Path(directory) / 'summary.json'
        provisional.write_text(json.dumps(payload, allow_nan=False), encoding='utf-8')
        validate_record(provisional, candidate)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=args.output.parent,
                                         prefix='.orbitterm-summary-', delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(json.dumps(payload, indent=2, sort_keys=True, allow_nan=False) + '\n')
            stream.flush()
        temporary.replace(args.output)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.SubprocessError, ET.ParseError):
        print('Performance summary failed: invalid metadata, metrics, or trace export.', file=sys.stderr)
        sys.exit(1)
