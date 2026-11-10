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
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

from evidence_validation import EvidenceArgumentParser, expected_commit, reject
from verify_apple_device_slo import PLATFORMS, SLOS, validate_record


def activity_metrics(root: ET.Element, target_pid: int) -> tuple[float, int, int]:
    """Read the named columns, including xctrace's interned value references.

    Ordinals, display labels and the first nonempty byte cell are not a schema
    contract. Repeated CPU/memory values are references, not missing samples.
    """
    if type(target_pid) is not int or target_pid <= 0:
        reject('target process must be a positive PID')
    tables = [node for node in root.iter() if any(
        child.tag == 'schema' and child.get('name') == 'activity-monitor-process-live'
        for child in node)]
    if len(tables) != 1:
        reject('trace must contain one supported Activity Monitor table')
    table = tables[0]
    if len(table.findall('schema')) != 1:
        reject('trace contains an ambiguous metric schema')
    schema = table.find('schema')
    columns = list(schema.findall('col'))
    required = {'pid': 'pid', 'duration': 'duration',
                'cpu-percent': 'system-cpu-percent',
                'memory-physical-footprint': 'size-in-bytes'}
    indices = {}
    for name, kind in required.items():
        matches = [i for i, col in enumerate(columns) if col.findtext('mnemonic') == name]
        if len(matches) != 1 or columns[matches[0]].findtext('engineering-type') != kind:
            reject('trace is missing a supported metric column')
        indices[name] = matches[0]

    ids = {}
    for node in root.iter():
        identity = node.get('id')
        if identity is not None:
            if identity in ids:
                reject('trace contains duplicate value identifiers')
            ids[identity] = node

    def resolve(node):
        visited = set()
        while node.get('ref') is not None:
            reference = node.get('ref')
            if (reference in visited or reference not in ids or node.get('id') is not None
                    or node.text and node.text.strip() or len(node)):
                reject('trace contains an invalid value reference')
            visited.add(reference)
            destination = ids[reference]
            if destination.tag != node.tag:
                reject('trace reference has the wrong metric type')
            node = destination
        return node

    def numeric(node, kind, *, integer=False, positive=False):
        node = resolve(node)
        if node.tag != kind or node.text is None:
            reject('trace contains a missing or unsupported numeric sample')
        if integer:
            if re.fullmatch(r'[0-9]+', node.text) is None:
                reject('trace contains a non-integer numeric sample')
            value = int(node.text)
            if positive and value == 0:
                reject('trace contains an invalid numeric sample')
            return value
        try:
            value = float(node.text)
        except (ValueError, OverflowError):
            reject('trace contains a malformed numeric sample')
        if not math.isfinite(value) or value < 0 or (positive and value == 0):
            reject('trace contains an invalid numeric sample')
        return value

    samples = []
    footprints = []
    for row in table.findall('row'):
        cells = list(row)
        if len(cells) != len(columns):
            reject('trace row does not match its metric schema')
        if numeric(cells[indices['pid']], 'pid', integer=True, positive=True) != target_pid:
            reject('trace contains samples from a different process')
        duration = numeric(cells[indices['duration']], 'duration', positive=True)
        footprints.append(numeric(cells[indices['memory-physical-footprint']],
                                  'size-in-bytes', integer=True, positive=True))
        cpu = resolve(cells[indices['cpu-percent']])
        # The initial live sample has no previous interval for a CPU delta.
        # This explicit missing marker is not an idle (zero CPU) sample.
        if cpu.tag == 'sentinel' and not cpu.attrib and cpu.text is None and not len(cpu):
            if samples:
                reject('trace contains an unmeasured interval after CPU sampling began')
            continue
        samples.append((numeric(cpu, 'system-cpu-percent'), duration))
    if not samples or not footprints:
        reject('Activity Monitor trace contains no measured CPU or footprint samples')
    # Sampling intervals vary; count repeated observations and weight them by
    # duration rather than averaging only the distinct exported values.
    scale = max(duration for _, duration in samples)
    weights = [duration / scale for _, duration in samples]
    total_weight = math.fsum(weights)
    try:
        average = math.fsum(cpu * (weight / total_weight)
                            for (cpu, _), weight in zip(samples, weights))
    except OverflowError:
        reject('trace contains an invalid CPU aggregate')
    if not math.isfinite(average):
        reject('trace contains an invalid CPU aggregate')
    # Keep precision through the gate: rounding 70.0004 to 70.000 would turn
    # an above-budget observation into a passing one.
    return average, max(footprints), len(samples)


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
    parser.add_argument("--target-pid", required=True, type=int)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--response-ms", required=True, type=float)
    parser.add_argument("--minimum-fps", required=True, type=float)
    parser.add_argument("--animation-hitches", required=True, type=int)
    args = parser.parse_args()

    candidate = expected_commit(args.build_commit)
    if (args.target_pid <= 0 or not math.isfinite(args.response_ms) or args.response_ms <= 0 or
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

    average_cpu, peak_footprint, sample_count = activity_metrics(root, args.target_pid)

    payload = {
        "schema_version": 2,
        "kind": "apple-device-performance",
        "build_commit": candidate,
        "platform": args.platform,
        "scenario": args.scenario,
        "run": args.run,
        "response_milliseconds": args.response_ms,
        "average_cpu_percent": average_cpu,
        "peak_footprint_bytes": peak_footprint,
        "minimum_frames_per_second": args.minimum_fps,
        "animation_hitches": args.animation_hitches,
        "trace_sha256": activity_digest,
        "frame_trace_sha256": frame_digest,
        "sample_count": sample_count,
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
