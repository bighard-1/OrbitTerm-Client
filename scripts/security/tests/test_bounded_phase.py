import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest


RUNNER = Path(__file__).resolve().parents[1] / 'run_bounded_phase.py'


class BoundedPhaseTests(unittest.TestCase):
    def run_phase(self, root, code, limit=5):
        report = root / 'phases.jsonl'
        result = subprocess.run(
            [sys.executable, str(RUNNER), '--phase', 'fixture', '--timeout', str(limit),
             '--report', str(report), '--', sys.executable, '-c', code],
            capture_output=True, text=True, timeout=12,
        )
        return result, json.loads(report.read_text())

    def test_actual_nonzero_status_is_not_lost_and_arguments_are_not_recorded(self):
        with tempfile.TemporaryDirectory() as directory:
            result, record = self.run_phase(Path(directory), 'import sys; sys.exit(7)')
            self.assertEqual(result.returncode, 7)
            self.assertEqual(record['status'], 'failed')
            self.assertNotIn('sys.exit', json.dumps(record))

    def test_hung_phase_becomes_explicit_timeout(self):
        with tempfile.TemporaryDirectory() as directory:
            result, record = self.run_phase(Path(directory), 'import time; time.sleep(1000)', 1)
            self.assertEqual(result.returncode, 124)
            self.assertEqual(record['status'], 'timed_out')

    def test_completed_parent_cannot_leave_a_running_descendant(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            heartbeat = root / 'heartbeat'
            child = (
                'import signal,time; from pathlib import Path; '
                'signal.signal(signal.SIGTERM, signal.SIG_IGN); '
                f'p=Path({str(heartbeat)!r}); '
                '\nwhile True:\n p.write_text(str(time.monotonic())); time.sleep(.03)'
            )
            parent = (
                'import subprocess,sys,time; from pathlib import Path; '
                f'subprocess.Popen([sys.executable,"-c",{child!r}]); '
                f'p=Path({str(heartbeat)!r}); '
                '\nwhile not p.exists(): time.sleep(.01)'
            )
            result, record = self.run_phase(root, parent)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(record['status'], 'passed')
            last = heartbeat.read_bytes()
            time.sleep(.15)
            self.assertEqual(heartbeat.read_bytes(), last)

    def test_missing_executable_is_not_reported_as_a_test_failure_or_success(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / 'phases.jsonl'
            result = subprocess.run(
                [sys.executable, str(RUNNER), '--phase', 'missing-tool', '--timeout', '1',
                 '--report', str(report), '--', str(Path(directory) / 'missing')],
                capture_output=True, timeout=5,
            )
            self.assertEqual(result.returncode, 127)
            self.assertEqual(json.loads(report.read_text())['status'], 'start_failed')


if __name__ == '__main__':
    unittest.main()
