#!/usr/bin/env python3
"""Validate strict, same-candidate desktop transfer/concurrency evidence."""

from __future__ import annotations

from collections import defaultdict
from pathlib import Path
import sys

from evidence_validation import (
    EvidenceArgumentParser, build_commit, expected_commit, fields, load_record, number, reject,
)


SCENARIO = 'three-assets-six-panes-3-gib-transfer'
PLATFORMS = {'windows-10', 'windows-11', 'macos'}
RUNS_PER_PLATFORM = 3
MAX_CLICK_RESPONSE_MS = 250
MAX_SESSION_SWITCH_MS = 500
MAX_PROGRESS_UPDATES_PER_SECOND = 8
MAX_CANCELING_STATE_MS = 1000
MAX_MEMORY_GROWTH_BYTES = 64 * 1024 * 1024
MIN_LATE_THROUGHPUT_RATIO = 0.70
FIELDS = {
    'schema_version', 'kind', 'build_commit', 'platform', 'scenario', 'run',
    'duration_seconds', 'max_click_response_ms', 'max_session_switch_ms',
    'blank_pane_count', 'stale_monitor_intervals', 'max_ui_progress_updates_per_second',
    'canceling_state_ms', 'memory_start_bytes', 'memory_end_bytes', 'late_window_throughput_ratio',
}


def validate_record(path: Path, candidate: str) -> tuple[str, int]:
    data = load_record(path)
    fields(data, FIELDS)
    if type(data['schema_version']) is not int or data['schema_version'] != 1:
        reject('unsupported concurrency evidence schema version')
    if data['kind'] != 'desktop-concurrency' or data['scenario'] != SCENARIO:
        reject('unexpected evidence kind or scenario')
    if not isinstance(data['platform'], str) or data['platform'] not in PLATFORMS:
        reject('unsupported concurrency platform')
    run = number(data, 'run', 1, RUNS_PER_PLATFORM, integer=True)
    build_commit(data, candidate)
    number(data, 'duration_seconds', 900)
    number(data, 'max_click_response_ms', 0, MAX_CLICK_RESPONSE_MS)
    number(data, 'max_session_switch_ms', 0, MAX_SESSION_SWITCH_MS)
    number(data, 'blank_pane_count', 0, 0, integer=True)
    number(data, 'stale_monitor_intervals', 0, 0, integer=True)
    number(data, 'max_ui_progress_updates_per_second', 0, MAX_PROGRESS_UPDATES_PER_SECOND)
    number(data, 'canceling_state_ms', 0, MAX_CANCELING_STATE_MS)
    number(data, 'memory_start_bytes', integer=True, positive=True)
    number(data, 'memory_end_bytes', integer=True, positive=True)
    if data['memory_end_bytes'] - data['memory_start_bytes'] > MAX_MEMORY_GROWTH_BYTES:
        reject('memory growth exceeds the published SLO')
    number(data, 'late_window_throughput_ratio', MIN_LATE_THROUGHPUT_RATIO, 1)
    return data['platform'], run


def validate_evidence(paths: list[Path], candidate: str) -> list[str]:
    candidate = expected_commit(candidate)
    observed = defaultdict(set)
    failures = []
    for index, path in enumerate(paths, 1):
        try:
            platform, run = validate_record(path, candidate)
            if run in observed[platform]:
                reject('duplicate platform/run record')
            observed[platform].add(run)
        except ValueError as error:
            failures.append(f'record {index}: {error}')
    for platform in sorted(PLATFORMS):
        if observed[platform] != {1, 2, 3}:
            failures.append(f'{platform}: requires three distinct measured runs')
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
        print('Desktop concurrency evidence failed:', file=sys.stderr)
        print('\n'.join(f'- {failure}' for failure in failures), file=sys.stderr)
        return 1
    print('Desktop concurrency evidence passed (9 same-candidate measured runs)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
