import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
DOWNLOADER = ROOT / 'scripts/security/download_verified.sh'
JAVA_SELECTOR = ROOT / 'scripts/security/select_runner_java.py'
spec = importlib.util.spec_from_file_location('runner_java', JAVA_SELECTOR)
runner_java = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner_java)


class VerifiedDownloadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.output = self.root / 'source.tar.gz'
        self.payload = b'fixed source archive fixture'
        self.digest = hashlib.sha256(self.payload).hexdigest()
        self.log = self.root / 'curl-calls.json'
        (self.root / 'curl').write_text(f'''#!{sys.executable}
import json, os, pathlib, sys
log = pathlib.Path(os.environ['CURL_CALLS'])
calls = json.loads(log.read_text()) if log.exists() else []
calls.append(sys.argv[1:]); log.write_text(json.dumps(calls))
target = pathlib.Path(sys.argv[sys.argv.index('--output') + 1])
mode = os.environ['CURL_MODE']
if mode == 'fail' or (mode == 'recover' and len(calls) == 1):
    target.write_bytes(b'incomplete'); sys.exit(56)
target.write_bytes(b'wrong digest' if mode == 'bad-hash' else {self.payload!r})
''')
        (self.root / 'curl').chmod(0o755)
        (self.root / 'sleep').write_text('#!/bin/sh\nexit 0\n')
        (self.root / 'sleep').chmod(0o755)

    def run_download(self, mode='success', url='https://primary.example/source',
                     fallback='https://publisher.example/source'):
        return subprocess.run(
            ['bash', '-c', 'source "$1"; download_and_verify "$2" "$3" "$4" "$5"',
             'fixture', str(DOWNLOADER), url, self.digest, str(self.output), fallback],
            env={**os.environ, 'PATH': f'{self.root}{os.pathsep}{os.environ["PATH"]}',
                 'CURL_CALLS': str(self.log), 'CURL_MODE': mode},
            capture_output=True, text=True, timeout=10,
        )

    def assert_no_partial(self):
        self.assertEqual(list(self.root.rglob('*.partial.*')), [])

    def test_new_archive_is_promoted_only_after_verification(self):
        self.assertEqual(self.run_download().returncode, 0)
        self.assertEqual(self.output.read_bytes(), self.payload)
        call = json.loads(self.log.read_text())[0]
        self.assertEqual(call[0], '--disable')
        self.assertEqual(call[call.index('--proto') + 1], '=https')
        self.assertEqual(call[call.index('--proto-redir') + 1], '=https')
        self.assertEqual(call[call.index('--max-time') + 1], '120')
        self.assertNotIn('--insecure', call)
        self.assert_no_partial()

    def test_valid_cached_archive_does_not_use_network(self):
        self.output.write_bytes(self.payload)
        self.assertEqual(self.run_download(mode='fail').returncode, 0)
        self.assertFalse(self.log.exists())

    def test_corrupt_cache_is_rejected_and_preserved_for_diagnosis(self):
        self.output.write_bytes(b'corrupt cache')
        self.assertNotEqual(self.run_download().returncode, 0)
        self.assertEqual(self.output.read_bytes(), b'corrupt cache')
        self.assertFalse(self.log.exists())

    def test_partial_network_failure_recovers_through_pinned_publisher(self):
        self.assertEqual(self.run_download(mode='recover').returncode, 0)
        calls = json.loads(self.log.read_text())
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0][-1], 'https://primary.example/source')
        self.assertEqual(calls[1][-1], 'https://publisher.example/source')
        self.assertEqual(self.output.read_bytes(), self.payload)
        self.assert_no_partial()

    def test_network_failure_is_bounded_and_never_caches_partial_data(self):
        self.output = self.root / 'cache with spaces' / 'source.tar.gz'
        result = self.run_download(mode='fail')
        self.assertEqual(result.returncode, 56)
        self.assertEqual(len(json.loads(self.log.read_text())), 3)
        self.assertIn('3/3 failed', result.stderr)
        self.assertFalse(self.output.exists())
        self.assert_no_partial()

    def test_checksum_failure_fails_closed_without_mirror_retry(self):
        self.assertNotEqual(self.run_download(mode='bad-hash').returncode, 0)
        self.assertEqual(len(json.loads(self.log.read_text())), 1)
        self.assertFalse(self.output.exists())
        self.assert_no_partial()

    def test_insecure_source_or_fallback_is_rejected_before_network(self):
        for args in ({'url': 'http://primary.example/source'},
                     {'fallback': 'http://publisher.example/source'}):
            with self.subTest(args=args):
                self.assertNotEqual(self.run_download(**args).returncode, 0)
                self.assertFalse(self.log.exists())


class HostedJavaTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / 'jdk with spaces'
        (self.home / 'bin').mkdir(parents=True)
        self.env = {'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'github-hosted',
                    'RUNNER_ARCH': 'ARM64', 'JAVA_HOME_17_arm64': str(self.home)}
        self.make_tools()

    def make_tools(self, version='17', arch='aarch64', compiler='javac 17.0.21'):
        for name, text in (('java', f'    java.specification.version = {version}\n    os.arch = {arch}'),
                           ('javac', compiler)):
            tool = self.home / 'bin' / name
            tool.write_text(f'#!{sys.executable}\nimport sys\nprint({text!r}, file=sys.stderr)\n')
            tool.chmod(0o755)

    def test_runtime_compiler_architecture_and_space_in_path_are_supported(self):
        self.assertEqual(runner_java.select_java(self.env), str(self.home.resolve()))
        self.make_tools(arch='amd64')
        env = {**self.env, 'RUNNER_ARCH': 'X64', 'JAVA_HOME_17_X64': str(self.home)}
        self.assertEqual(runner_java.select_java(env), str(self.home.resolve()))

    def test_unadvertised_java_uses_setup_java_fallback(self):
        env = {k: v for k, v in self.env.items() if not k.startswith('JAVA_HOME')}
        self.assertIsNone(runner_java.select_java(env))

    def test_local_or_self_hosted_java_is_not_adopted(self):
        for changes in ({'GITHUB_ACTIONS': 'false'}, {'RUNNER_ENVIRONMENT': 'self-hosted'}):
            self.assertIsNone(runner_java.select_java({**self.env, **changes}))

    def test_wrong_runtime_architecture_or_compiler_fails_closed(self):
        for settings in ({'version': '21'}, {'arch': 'amd64'}, {'compiler': 'javac 21.0.1'}):
            with self.subTest(settings=settings):
                self.make_tools(**settings)
                with self.assertRaises(RuntimeError):
                    runner_java.select_java(self.env)

    def test_incomplete_jdk_or_environment_injection_is_rejected(self):
        (self.home / 'bin/javac').unlink()
        with self.assertRaises(RuntimeError):
            runner_java.select_java(self.env)
        for path in ('relative/path', f'{self.home}\nINJECTED=true'):
            with self.assertRaises(RuntimeError):
                runner_java.select_java({**self.env, 'JAVA_HOME_17_arm64': path})

    def test_github_environment_is_written_only_after_validation(self):
        paths = {name: str(self.root / name) for name in ('GITHUB_OUTPUT', 'GITHUB_ENV', 'GITHUB_PATH')}
        env = {**os.environ, **self.env, **paths}
        result = subprocess.run([sys.executable, str(JAVA_SELECTOR)], env=env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(Path(paths['GITHUB_OUTPUT']).read_text(), 'available=true\n')
        self.assertEqual(Path(paths['GITHUB_ENV']).read_text(), f'JAVA_HOME={self.home.resolve()}\n')
        self.assertEqual(Path(paths['GITHUB_PATH']).read_text(), f'{self.home.resolve()}/bin\n')
        self.make_tools(version='21')
        for value in paths.values():
            Path(value).unlink()
        result = subprocess.run([sys.executable, str(JAVA_SELECTOR)], env=env,
                                capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(Path(value).exists() for value in paths.values()))


if __name__ == '__main__':
    unittest.main()
