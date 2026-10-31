#!/usr/bin/env python3
"""Bound a CI phase, reap its process group, and retain its actual outcome."""

import argparse
import datetime
import json
import os
from pathlib import Path
import signal
import subprocess
import time


class Interrupted(Exception):
    def __init__(self, signum):
        self.signum = signum


def stop_group(process):
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        pass
    # The group may still contain a descendant after its leader has exited.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phase', required=True)
    parser.add_argument('--timeout', type=int, required=True)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if args.timeout <= 0 or not command:
        parser.error('a positive timeout and a command are required')

    args.report.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
    process = None
    status, code = 'start_failed', 127

    def interrupt(signum, _frame):
        raise Interrupted(signum)

    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, interrupt)
    print(f'[START] {args.phase} (limit {args.timeout}s)', flush=True)
    try:
        process = subprocess.Popen(command, start_new_session=True)
        code = process.wait(timeout=args.timeout)
        code = 128 - code if code < 0 else code
        status = 'passed' if code == 0 else 'failed'
    except subprocess.TimeoutExpired:
        status, code = 'timed_out', 124
        print(f'[FAIL] {args.phase} exceeded {args.timeout}s', flush=True)
    except Interrupted as error:
        status, code = 'interrupted', 128 + error.signum
    except OSError as error:
        # Do not persist command arguments: future callers may carry secrets.
        print(f'[FAIL] {args.phase} could not start (errno={error.errno})', flush=True)
    finally:
        # Once shutdown starts, a second runner signal must not strand children.
        for signum in (signal.SIGTERM, signal.SIGINT):
            signal.signal(signum, signal.SIG_IGN)
        if process is not None:
            stop_group(process)
        elapsed = round(time.monotonic() - started, 3)
        record = dict(phase=args.phase, started_at=timestamp, elapsed_seconds=elapsed,
                      limit_seconds=args.timeout, status=status, exit_code=code)
        with args.report.open('a', encoding='utf-8') as stream:
            stream.write(json.dumps(record) + '\n')
        print(f'[END] {args.phase}: {status}, exit={code}, elapsed={elapsed}s', flush=True)
    return code


if __name__ == '__main__':
    raise SystemExit(main())
