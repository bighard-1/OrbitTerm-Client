"""Strict, payload-free validation shared by release performance evidence."""

from __future__ import annotations

import json
import argparse
import math
from pathlib import Path
import re
import sys


MAX_RECORD_BYTES = 1024 * 1024
COMMIT_PATTERN = re.compile(r'[0-9a-f]{40}')
SHA256_PATTERN = re.compile(r'[0-9a-f]{64}')


class EvidenceArgumentParser(argparse.ArgumentParser):
    def error(self, _message):
        self.print_usage(sys.stderr)
        self.exit(2, 'Invalid performance-evidence arguments.\n')


def reject(message: str) -> None:
    raise ValueError(message)


def reject_constant(_value: str):
    reject('non-standard JSON numeric constant')


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            reject('duplicate JSON field')
        result[key] = value
    return result


def load_record(path: Path) -> dict:
    try:
        with path.open('rb') as stream:
            raw = stream.read(MAX_RECORD_BYTES + 1)
    except OSError:
        reject('cannot read evidence record')
    if len(raw) > MAX_RECORD_BYTES:
        reject('evidence record exceeds size limit')
    try:
        data = json.loads(raw.decode('utf-8'), object_pairs_hook=unique_object,
                          parse_constant=reject_constant)
    except (UnicodeError, ValueError, RecursionError):
        reject('invalid, duplicate-field, or non-standard JSON')
    if not isinstance(data, dict):
        reject('evidence record must be an object')
    return data


def fields(record: dict, expected: set[str]) -> None:
    # An allowlist rejects unknown and sensitive payloads without printing
    # their field names or contents into release logs.
    if set(record) != expected:
        reject('evidence fields do not match the required schema')


def expected_commit(value: str) -> str:
    if not isinstance(value, str) or COMMIT_PATTERN.fullmatch(value) is None:
        reject('expected build commit must be a full lowercase 40-character Git SHA')
    return value


def build_commit(record: dict, expected: str) -> None:
    value = record.get('build_commit')
    if not isinstance(value, str) or COMMIT_PATTERN.fullmatch(value) is None:
        reject('record build commit must be a full lowercase Git SHA')
    if value != expected:
        reject('record build commit differs from the expected candidate')


def number(record: dict, key: str, minimum=0, maximum=None, *, integer=False,
           positive=False):
    value = record.get(key)
    if type(value) not in (int, float) or (integer and type(value) is not int):
        reject(f'{key} must have the required numeric type')
    try:
        finite = math.isfinite(value)
    except OverflowError:
        finite = False
    if not finite:
        reject(f'{key} must be finite and representable')
    if value < minimum or (positive and value == 0):
        reject(f'{key} is below the allowed range')
    if maximum is not None and value > maximum:
        reject(f'{key} exceeds the allowed range')
    return value


def sha256(record: dict, key: str) -> str:
    value = record.get(key)
    if not isinstance(value, str) or SHA256_PATTERN.fullmatch(value) is None:
        reject(f'{key} must be a lowercase SHA-256')
    return value
