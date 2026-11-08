"""Synthetic evidence only: these fixtures must never be release evidence."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


PERFORMANCE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PERFORMANCE))
import evidence_validation as common
import summarize_xctrace_activity as summarize
import verify_apple_device_slo as apple
import verify_desktop_concurrency_evidence as desktop

COMMIT = '1' * 40
OTHER_COMMIT = '2' * 40
SECRET = 'SYNTHETIC_PRIVATE_MARKER'


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def apple_record(platform='macos', scenario='cold_launch', run=1):
    identity = f'{platform}/{scenario}/{run}'
    return dict(schema_version=2, kind='apple-device-performance', build_commit=COMMIT,
                platform=platform, scenario=scenario, run=run,
                response_milliseconds=100, average_cpu_percent=10,
                peak_footprint_bytes=100 * 1024 * 1024,
                minimum_frames_per_second=60, animation_hitches=0,
                trace_sha256=digest(identity + '/activity'),
                frame_trace_sha256=digest(identity + '/frame'), sample_count=10)


def desktop_record(platform='macos', run=1):
    return dict(schema_version=1, kind='desktop-concurrency', build_commit=COMMIT,
                platform=platform, scenario=desktop.SCENARIO, run=run,
                duration_seconds=900, max_click_response_ms=250,
                max_session_switch_ms=500, blank_pane_count=0, stale_monitor_intervals=0,
                max_ui_progress_updates_per_second=8, canceling_state_ms=1000,
                memory_start_bytes=100 * 1024 * 1024,
                memory_end_bytes=164 * 1024 * 1024, late_window_throughput_ratio=0.70)


class EvidenceFixtures(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def write(self, data, name='record.json'):
        path = self.root / name
        path.write_text(json.dumps(data), encoding='utf-8')
        return path

    def records(self, module):
        if module is apple:
            data = [apple_record(p, s, r) for p in sorted(apple.PLATFORMS)
                    for s in apple.SLOS for r in (1, 2, 3)]
        else:
            data = [desktop_record(p, r) for p in sorted(desktop.PLATFORMS) for r in (1, 2, 3)]
        return [self.write(d, f'{module.__name__}-{i}.json') for i, d in enumerate(data)]

    def change(self, path, **updates):
        data = json.loads(path.read_text())
        data.update(updates)
        path.write_text(json.dumps(data))

    def cli(self, module, paths, candidate=COMMIT):
        return subprocess.run([sys.executable, str(Path(module.__file__)),
                               '--expected-build-commit', candidate, *map(str, paths)],
                              capture_output=True, text=True, timeout=15)


class EvidenceTests(EvidenceFixtures):
    def test_complete_apple_matrix_and_cli_pass(self):
        paths = self.records(apple)
        self.assertEqual(len(paths), 48)
        self.assertEqual(apple.validate_evidence(paths, COMMIT), [])
        result = self.cli(apple, paths)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('48 measured runs', result.stdout)

    def test_complete_desktop_matrix_at_published_thresholds_passes(self):
        paths = self.records(desktop)
        self.assertEqual(desktop.validate_evidence(paths, COMMIT), [])
        self.assertEqual(self.cli(desktop, paths).returncode, 0)

    def test_original_apple_negative_and_metadata_free_probe_is_rejected(self):
        paths = []
        for scenario in apple.SLOS:
            paths.append(self.write(dict(scenario=scenario, response_milliseconds=-1,
                                         average_cpu_percent=-1, peak_footprint_bytes=-1,
                                         minimum_frames_per_second=60, animation_hitches=-1),
                                    f'old-{scenario}.json'))
        result = self.cli(apple, paths)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn('passed', result.stdout)

    def test_original_desktop_nan_negative_and_mixed_candidate_probe_is_rejected(self):
        paths = self.records(desktop)
        for i, path in enumerate(paths):
            self.change(path, max_click_response_ms=-1, max_session_switch_ms=-1,
                        canceling_state_ms=0, late_window_throughput_ratio=float('nan'),
                        build_commit=COMMIT if i < 3 else OTHER_COMMIT)
        self.assertEqual(self.cli(desktop, paths).returncode, 1)

    def test_every_numeric_field_rejects_boolean_nonfinite_and_negative(self):
        for module, factory, keys in (
            (apple, apple_record, ('response_milliseconds', 'average_cpu_percent',
                                  'peak_footprint_bytes', 'minimum_frames_per_second',
                                  'animation_hitches', 'sample_count', 'run')),
            (desktop, desktop_record, ('duration_seconds', 'max_click_response_ms',
                                      'max_session_switch_ms', 'blank_pane_count',
                                      'stale_monitor_intervals', 'max_ui_progress_updates_per_second',
                                      'canceling_state_ms', 'memory_start_bytes', 'memory_end_bytes',
                                      'late_window_throughput_ratio', 'run')),
        ):
            for key in keys:
                for value in (True, False, -1, float('nan'), float('inf'), -float('inf')):
                    with self.subTest(module=module.__name__, key=key, value=value):
                        data = factory()
                        data[key] = value
                        with self.assertRaises(ValueError):
                            module.validate_record(self.write(data), COMMIT)

    def test_counts_and_schema_versions_require_actual_integers(self):
        for module, factory, keys in (
            (apple, apple_record, ('schema_version', 'run', 'peak_footprint_bytes',
                                  'animation_hitches', 'sample_count')),
            (desktop, desktop_record, ('schema_version', 'run', 'blank_pane_count',
                                      'stale_monitor_intervals', 'memory_start_bytes', 'memory_end_bytes')),
        ):
            for key in keys:
                for value in (True, 1.0):
                    with self.subTest(module=module.__name__, key=key, value=value):
                        data = factory()
                        data[key] = value
                        with self.assertRaises(ValueError):
                            module.validate_record(self.write(data), COMMIT)

    def test_zero_placeholders_are_rejected_but_idle_cpu_is_allowed(self):
        for key in ('response_milliseconds', 'peak_footprint_bytes',
                    'minimum_frames_per_second', 'sample_count'):
            data = apple_record()
            data[key] = 0
            with self.subTest(key=key), self.assertRaises(ValueError):
                apple.validate_record(self.write(data), COMMIT)
        data = apple_record()
        data['average_cpu_percent'] = 0
        apple.validate_record(self.write(data), COMMIT)

    def test_malformed_duplicate_nonobject_utf8_and_huge_json_fail_safely(self):
        path = self.root / (SECRET + '.json')
        for content in (b'{', b'[]', b'null', b'{"a":1,"a":2}', b'\xff',
                        b' ' * (common.MAX_RECORD_BYTES + 1), b'[' * 1500 + b']' * 1500):
            path.write_bytes(content)
            for module in (apple, desktop):
                with self.subTest(content=content[:20], module=module.__name__):
                    result = self.cli(module, [path])
                    self.assertEqual(result.returncode, 1)
                    self.assertNotIn(SECRET, result.stdout + result.stderr)
                    self.assertNotIn('Traceback', result.stderr)

    def test_missing_file_does_not_echo_private_path(self):
        path = self.root / SECRET / 'missing.json'
        for module in (apple, desktop):
            result = self.cli(module, [path])
            self.assertEqual(result.returncode, 1)
            self.assertNotIn(SECRET, result.stdout + result.stderr)

    def test_overflowing_numeric_literals_and_huge_integers_fail_closed(self):
        for module, factory, key in ((apple, apple_record, 'average_cpu_percent'),
                                     (desktop, desktop_record, 'late_window_throughput_ratio')):
            data = factory()
            data[key] = 'OVERFLOW'
            path = self.root / 'overflow.json'
            path.write_text(json.dumps(data).replace('"OVERFLOW"', '1e999'))
            with self.assertRaises(ValueError):
                module.validate_record(path, COMMIT)
            data[key] = 10 ** 400
            with self.assertRaises(ValueError):
                module.validate_record(self.write(data), COMMIT)

    def test_missing_unknown_nested_and_sensitive_fields_are_rejected(self):
        for module, factory in ((apple, apple_record), (desktop, desktop_record)):
            for key in tuple(factory()):
                data = factory()
                del data[key]
                with self.subTest(module=module.__name__, missing=key), self.assertRaises(ValueError):
                    module.validate_record(self.write(data), COMMIT)
            data = factory()
            data[SECRET] = {'token': SECRET}
            result = self.cli(module, [self.write(data, SECRET + '.json')])
            self.assertEqual(result.returncode, 1)
            self.assertNotIn(SECRET, result.stdout + result.stderr)

    def test_unhashable_or_unknown_platform_and_scenario_are_safe_failures(self):
        for module, factory in ((apple, apple_record), (desktop, desktop_record)):
            for key in ('platform', 'scenario'):
                for value in ([], {}, None, SECRET):
                    data = factory()
                    data[key] = value
                    result = self.cli(module, [self.write(data)])
                    with self.subTest(module=module.__name__, key=key, value=value):
                        self.assertEqual(result.returncode, 1)
                        self.assertNotIn('Traceback', result.stderr)
                        self.assertNotIn(SECRET, result.stderr)

    def test_candidate_must_be_full_lowercase_and_match_every_record(self):
        for module, factory in ((apple, apple_record), (desktop, desktop_record)):
            for value in ('a' * 7, 'A' * 40, 'z' * 40, OTHER_COMMIT, [], True):
                data = factory()
                data['build_commit'] = value
                with self.subTest(module=module.__name__, value=value), self.assertRaises(ValueError):
                    module.validate_record(self.write(data), COMMIT)
            result = self.cli(module, [self.write(factory())], candidate=SECRET)
            self.assertEqual(result.returncode, 1)
            self.assertNotIn(SECRET, result.stderr)

    def test_missing_platform_run_and_duplicate_cannot_complete_a_matrix(self):
        for module in (apple, desktop):
            paths = self.records(module)
            with self.subTest(module=module.__name__):
                self.assertTrue(module.validate_evidence(paths[:-1], COMMIT))
                self.assertTrue(module.validate_evidence(paths[:-1] + [paths[0]], COMMIT))
                self.assertTrue(module.validate_evidence(paths + [paths[0]], COMMIT))
                only_mac = [p for p in paths if json.loads(p.read_text())['platform'] == 'macos']
                self.assertTrue(module.validate_evidence(only_mac, COMMIT))

    def test_mixed_candidates_cannot_be_combined(self):
        for module in (apple, desktop):
            paths = self.records(module)
            self.change(paths[-1], build_commit=OTHER_COMMIT)
            self.assertTrue(module.validate_evidence(paths, COMMIT))

    def test_trace_hashes_are_valid_distinct_and_not_reused(self):
        paths = self.records(apple)
        original = json.loads(paths[0].read_text())
        for value in ('', 'A' * 64, 'a' * 63, [], True):
            data = apple_record()
            data['trace_sha256'] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                apple.validate_record(self.write(data), COMMIT)
        self.change(paths[0], frame_trace_sha256=original['trace_sha256'])
        self.assertTrue(apple.validate_evidence(paths, COMMIT))
        paths[0].write_text(json.dumps(original))
        self.change(paths[1], trace_sha256=original['frame_trace_sha256'])
        self.assertTrue(apple.validate_evidence(paths, COMMIT))

    def test_apple_uses_median_response_and_mean_cpu_as_published(self):
        paths = self.records(apple)
        for path, response, cpu in zip(paths[:3], (6000, 100, 100), (90, 40, 40)):
            self.change(path, response_milliseconds=response, average_cpu_percent=cpu)
        self.assertEqual(apple.validate_evidence(paths, COMMIT), [])
        self.change(paths[1], response_milliseconds=6000)
        self.assertTrue(apple.validate_evidence(paths, COMMIT))

    def test_apple_exact_slo_boundaries_pass(self):
        paths = self.records(apple)
        for path in paths:
            data = json.loads(path.read_text())
            response, cpu, memory, fps, hitches = apple.SLOS[data['scenario']]
            self.change(path, response_milliseconds=response, average_cpu_percent=cpu,
                        peak_footprint_bytes=memory, minimum_frames_per_second=fps,
                        animation_hitches=hitches)
        self.assertEqual(apple.validate_evidence(paths, COMMIT), [])

    def test_apple_mean_cpu_and_worst_memory_frame_hitches_enforce_slos(self):
        for metric, value in (('average_cpu_percent', 300),
                              ('peak_footprint_bytes', 361 * 1024 * 1024),
                              ('minimum_frames_per_second', 44), ('animation_hitches', 3)):
            with self.subTest(metric=metric):
                paths = self.records(apple)
                self.change(paths[0], **{metric: value})
                self.assertTrue(apple.validate_evidence(paths, COMMIT))

    def test_desktop_all_slo_boundaries_are_enforced(self):
        for key, value in (('duration_seconds', 899), ('max_click_response_ms', 251),
                           ('max_session_switch_ms', 501), ('blank_pane_count', 1),
                           ('stale_monitor_intervals', 1), ('max_ui_progress_updates_per_second', 9),
                           ('canceling_state_ms', 1001), ('memory_end_bytes', 164 * 1024 * 1024 + 1),
                           ('late_window_throughput_ratio', 0.69), ('late_window_throughput_ratio', 1.01)):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                data = desktop_record()
                data[key] = value
                desktop.validate_record(self.write(data), COMMIT)

    def test_bad_cli_arguments_do_not_echo_input(self):
        for module in (apple, desktop, summarize):
            result = subprocess.run([sys.executable, module.__file__, '--' + SECRET],
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 2)
            self.assertNotIn(SECRET, result.stderr)

    def test_release_shell_entry_requires_and_checks_expected_candidate(self):
        paths = self.records(apple)
        script = PERFORMANCE.parent / 'security/check_apple_device_performance_evidence.sh'
        result = subprocess.run(['bash', str(script), str(self.root), COMMIT],
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = subprocess.run(['bash', str(script), str(self.root), OTHER_COMMIT],
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn('passed', result.stdout)
        result = subprocess.run(['bash', str(script), str(self.root)],
                                capture_output=True, text=True, timeout=15)
        self.assertNotEqual(result.returncode, 0)


class SummaryTests(EvidenceFixtures):
    def captures(self):
        activity = self.root / 'activity.trace'
        frame = self.root / 'frame.trace'
        activity.mkdir()
        frame.mkdir()
        (activity / 'capture.bin').write_bytes(b'activity fixture')
        (frame / 'capture.bin').write_bytes(b'frame fixture')
        return activity, frame

    def summary_args(self, activity, frame, output):
        return ['summary', '--trace', str(activity), '--frame-trace', str(frame),
                '--scenario', 'cold_launch', '--build-commit', COMMIT, '--platform', 'macos',
                '--run', '1', '--output', str(output), '--response-ms', '100',
                '--minimum-fps', '60', '--animation-hitches', '0']

    def exported_activity(self, command, **_kwargs):
        path = Path(command[command.index('--output') + 1])
        path.write_text('<trace><row><system-cpu-percent>10</system-cpu-percent>'
                        + '<unused/>' * 9 + '<size-in-bytes>104857600</size-in-bytes>'
                        + '</row></trace>')

    def test_summary_producer_emits_the_exact_consumer_schema(self):
        activity, frame = self.captures()
        output = self.root / 'summary.json'
        with patch.object(sys, 'argv', self.summary_args(activity, frame, output)), \
                patch.object(summarize.subprocess, 'run', side_effect=self.exported_activity):
            self.assertEqual(summarize.main(), 0)
        data = apple.validate_record(output, COMMIT)
        self.assertEqual(data['sample_count'], 1)
        self.assertEqual(set(data), apple.FIELDS)
        self.assertFalse(list(self.root.glob('.orbitterm-summary-*')))

    def test_failed_export_leaves_existing_summary_unchanged(self):
        activity, frame = self.captures()
        output = self.root / 'summary.json'
        output.write_bytes(b'original summary')
        with patch.object(sys, 'argv', self.summary_args(activity, frame, output)), \
                patch.object(summarize.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'fixture')):
            with self.assertRaises(subprocess.CalledProcessError):
                summarize.main()
        self.assertEqual(output.read_bytes(), b'original summary')

    def test_nonfinite_cli_metrics_fail_before_export(self):
        activity, frame = self.captures()
        output = self.root / 'summary.json'
        args = self.summary_args(activity, frame, output)
        for value in ('nan', 'inf', '-1', '0'):
            args[args.index('--response-ms') + 1] = value
            with patch.object(sys, 'argv', args), patch.object(summarize.subprocess, 'run') as export:
                with self.assertRaises(ValueError):
                    summarize.main()
                export.assert_not_called()
                self.assertFalse(output.exists())

    def test_trace_digest_streams_stably_and_rejects_empty_or_symlinked_packages(self):
        activity, _frame = self.captures()
        before = summarize.trace_digest(activity)
        renamed = self.root / 'renamed.trace'
        shutil.copytree(activity, renamed)
        self.assertEqual(summarize.trace_digest(renamed), before)
        (renamed / 'capture.bin').write_bytes(b'changed')
        self.assertNotEqual(summarize.trace_digest(renamed), before)
        empty = self.root / 'empty.trace'
        empty.mkdir()
        with self.assertRaises(ValueError):
            summarize.trace_digest(empty)
        empty_file = self.root / 'empty-file.trace'
        empty_file.touch()
        with self.assertRaises(ValueError):
            summarize.trace_digest(empty_file)
        (empty / 'reference').symlink_to(activity / 'capture.bin')
        with self.assertRaises(ValueError):
            summarize.trace_digest(empty)

    def test_trace_numeric_samples_reject_nonfinite_negative_and_malformed(self):
        import xml.etree.ElementTree as ET
        for value in ('nan', 'inf', '-1', 'bad-value'):
            root = ET.fromstring(f'<row><system-cpu-percent>{value}</system-cpu-percent></row>')
            with self.subTest(value=value), self.assertRaises(ValueError):
                summarize.values(root, 'system-cpu-percent')

    def test_invalid_footprint_export_does_not_replace_existing_summary(self):
        activity, frame = self.captures()
        output = self.root / 'summary.json'
        output.write_bytes(b'original summary')
        for value in ('nan', 'inf', '-1', '0', '1.5'):
            def exporter(command, **kwargs):
                self.exported_activity(command, **kwargs)
                path = Path(command[command.index('--output') + 1])
                path.write_text(path.read_text().replace('104857600', value))
            with self.subTest(value=value), patch.object(sys, 'argv', self.summary_args(activity, frame, output)), \
                    patch.object(summarize.subprocess, 'run', side_effect=exporter):
                with self.assertRaises(ValueError):
                    summarize.main()
                self.assertEqual(output.read_bytes(), b'original summary')

    def test_producer_cli_sanitizes_export_errors_and_keeps_existing_output(self):
        activity, frame = self.captures()
        output = self.root / (SECRET + '.json')
        output.write_bytes(b'original summary')
        binary = self.root / 'xcrun'
        binary.write_text('#!/bin/sh\necho ' + SECRET + ' >&2\nexit 7\n')
        binary.chmod(0o755)
        args = self.summary_args(activity, frame, output)
        result = subprocess.run([sys.executable, str(PERFORMANCE / 'summarize_xctrace_activity.py'),
                                 *args[1:]], env={**os.environ, 'PATH': str(self.root) + os.pathsep + os.environ['PATH']},
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(SECRET, result.stdout + result.stderr)
        self.assertNotIn('Traceback', result.stderr)
        self.assertEqual(output.read_bytes(), b'original summary')


if __name__ == '__main__':
    unittest.main()
