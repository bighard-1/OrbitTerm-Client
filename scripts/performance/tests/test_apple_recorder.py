"""Recorder targeting contract; fake xcrun never starts an app or a trace."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'record_apple_device_slo.sh'


class RecorderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.capture = self.root / 'arguments.json'
        binary = self.root / 'xcrun'
        binary.write_text('#!/usr/bin/env python3\nimport json, os, sys\n'
                          'open(os.environ["RECORDER_TEST_ARGS"], "w").write(json.dumps(sys.argv[1:]))\n')
        binary.chmod(0o755)
        self.env = {**os.environ, 'PATH': str(self.root) + os.pathsep + os.environ['PATH'],
                    'RECORDER_TEST_ARGS': str(self.capture)}
        self.base = ['--scenario', 'unlock', '--device', 'fixture-device',
                     '--output', str(self.root / 'new.trace')]

    def run_recorder(self, args):
        return subprocess.run(['bash', str(SCRIPT), *args], env=self.env,
                              capture_output=True, text=True, timeout=10)

    def test_explicit_pid_is_attached_and_signposts_are_enabled(self):
        result = self.run_recorder(self.base + ['--pid', '42'])
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads(self.capture.read_text())
        self.assertEqual(args[-2:], ['--attach', '42'])
        self.assertEqual(args[args.index('--instrument') + 1], 'Points of Interest')
        self.assertNotIn('OrbitTerm', args)
        self.assertNotIn('--all-processes', args)

    def test_cold_launch_requires_launch_and_preserves_a_target_with_spaces(self):
        args = self.base.copy()
        args[args.index('--scenario') + 1] = 'cold_launch'
        target = '/private/fixture/OrbitTerm QA.app'
        result = self.run_recorder(args + ['--launch', target])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.capture.read_text())[-3:], ['--launch', '--', target])

    def test_ambiguous_missing_or_incompatible_targets_do_not_start_xctrace(self):
        for extra in ([], ['--pid', 'OrbitTerm'], ['--pid', '0'], ['--pid', '-1'],
                      ['--pid', '42', '--launch', '/fixture/app'], ['--launch', '/fixture/app']):
            with self.subTest(extra=extra):
                self.assertEqual(self.run_recorder(self.base + extra).returncode, 2)
                self.assertFalse(self.capture.exists())
        args = self.base.copy()
        args[args.index('--scenario') + 1] = 'cold_launch'
        self.assertEqual(self.run_recorder(args + ['--pid', '42']).returncode, 2)
        self.assertFalse(self.capture.exists())

    def test_missing_values_and_invalid_duration_template_are_private_failures(self):
        secret = 'private-fixture-marker'
        invalid = [self.base + ['--pid'], self.base + ['--pid', '--launch'],
                   self.base + ['--pid', '42', '--duration', secret],
                   self.base + ['--pid', '42', '--template', secret],
                   ['--scenario', secret]]
        for args in invalid:
            with self.subTest(args=args):
                result = self.run_recorder(args)
                self.assertEqual(result.returncode, 2)
                self.assertNotIn(secret, result.stderr + result.stdout)
                self.assertFalse(self.capture.exists())

    def test_existing_or_symlinked_output_is_never_reused(self):
        output = self.root / 'new.trace'
        output.mkdir()
        self.assertEqual(self.run_recorder(self.base + ['--pid', '42']).returncode, 2)
        output.rmdir()
        output.symlink_to(self.root / 'missing.trace')
        self.assertEqual(self.run_recorder(self.base + ['--pid', '42']).returncode, 2)
        self.assertFalse(self.capture.exists())


if __name__ == '__main__':
    unittest.main()
