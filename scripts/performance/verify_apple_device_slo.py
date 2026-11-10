#!/usr/bin/env python3
"""Validate complete, same-candidate macOS and iOS performance evidence."""

from __future__ import annotations

from collections import defaultdict
from pathlib import Path
import statistics
import sys

from evidence_validation import (
    EvidenceArgumentParser, build_commit, expected_commit, fields, load_record, number, reject, sha256,
)


SLOS = {
    'cold_launch': (3500, 85, 360 * 1024 * 1024, 45, 2),
    'unlock': (2000, 90, 360 * 1024 * 1024, 45, 1),
    'terminal_first_frame': (3500, 75, 420 * 1024 * 1024, 45, 2),
    'terminal_long_output': (250, 80, 440 * 1024 * 1024, 45, 3),
    'docker_log_refresh': (3500, 70, 420 * 1024 * 1024, 45, 2),
    'monitor_refresh': (3500, 70, 420 * 1024 * 1024, 45, 2),
    'sftp_directory_refresh': (3500, 70, 420 * 1024 * 1024, 45, 2),
    'sync_round_trip': (3500, 70, 420 * 1024 * 1024, 45, 2),
}
PLATFORMS = {'macos', 'ios'}
RUNS = {1, 2, 3}
FIELDS = {
    'schema_version', 'kind', 'build_commit', 'platform', 'scenario', 'run',
    'response_milliseconds', 'average_cpu_percent', 'peak_footprint_bytes',
    'minimum_frames_per_second', 'animation_hitches', 'trace_sha256',
    'frame_trace_sha256', 'sample_count',
}


def validate_record(path: Path, candidate: str) -> dict:
    data = load_record(path)
    fields(data, FIELDS)
    if type(data['schema_version']) is not int or data['schema_version'] != 2:
        reject('unsupported Apple evidence schema version')
    if data['kind'] != 'apple-device-performance':
        reject('unexpected evidence kind')
    build_commit(data, candidate)
    if not isinstance(data['platform'], str) or data['platform'] not in PLATFORMS:
        reject('unsupported Apple platform')
    if not isinstance(data['scenario'], str) or data['scenario'] not in SLOS:
        reject('unknown Apple performance scenario')
    number(data, 'run', 1, 3, integer=True)
    number(data, 'response_milliseconds', positive=True)
    number(data, 'average_cpu_percent')
    number(data, 'peak_footprint_bytes', integer=True, positive=True)
    number(data, 'minimum_frames_per_second', positive=True)
    number(data, 'animation_hitches', integer=True)
    number(data, 'sample_count', integer=True, positive=True)
    sha256(data, 'trace_sha256')
    sha256(data, 'frame_trace_sha256')
    return data


def validate_evidence(paths: list[Path], candidate: str) -> list[str]:
    candidate = expected_commit(candidate)
    observed = defaultdict(dict)
    traces = set()
    failures = []
    for index, path in enumerate(paths, 1):
        try:
            data = validate_record(path, candidate)
            group = (data['platform'], data['scenario'])
            if data['run'] in observed[group]:
                reject('duplicate platform/scenario/run record')
            digests = {data['trace_sha256'], data['frame_trace_sha256']}
            if len(digests) != 2 or digests.intersection(traces):
                reject('a trace is reused for multiple captures or records')
            observed[group][data['run']] = data
            traces.update(digests)
        except ValueError as error:
            failures.append(f'record {index}: {error}')
    for platform in sorted(PLATFORMS):
        for scenario, limits in SLOS.items():
            runs = observed[(platform, scenario)]
            if set(runs) != RUNS:
                failures.append(f'{platform}/{scenario}: requires three distinct measured runs')
                continue
            rows = list(runs.values())
            response, cpu, memory, fps, hitches = limits
            # Match the published contract: median response, mean CPU, and
            # worst observed memory/frame metrics across the three runs.
            checks = (
                ('response_milliseconds', statistics.median(r['response_milliseconds'] for r in rows) <= response),
                ('average_cpu_percent', statistics.mean(r['average_cpu_percent'] for r in rows) <= cpu),
                ('peak_footprint_bytes', max(r['peak_footprint_bytes'] for r in rows) <= memory),
                ('minimum_frames_per_second', min(r['minimum_frames_per_second'] for r in rows) >= fps),
                ('animation_hitches', max(r['animation_hitches'] for r in rows) <= hitches),
            )
            for metric, passed in checks:
                if not passed:
                    failures.append(f'{platform}/{scenario}: {metric} exceeds the published SLO')
    return failures


def main() -> int:
    parser = EvidenceArgumentParser(description=__doc__)
    parser.add_argument('--expected-build-commit', required=True)
    parser.add_argument('evidence', type=Path, nargs='+')
    args = parser.parse_args()
    try:
        failures = validate_evidence(args.evidence, args.expected_build_commit)
    except ValueError as error:
        failures = [str(error)]
    if failures:
        print('Apple device performance SLO evidence failed:', file=sys.stderr)
        print('\n'.join(f'- {failure}' for failure in failures), file=sys.stderr)
        return 1
    print('Apple device performance SLO evidence passed (2 platforms, 8 scenarios, 48 measured runs)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
