import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


RUNNER = Path(__file__).resolve().parents[1] / "run_apple_ui_tests.sh"


class AppleUIEvidenceTests(unittest.TestCase):
    def run_fixture(self, root, *, test_exit=0, create_bundle=True, export_exit=0, blocked_output=False):
        tools = root / "tools"
        tools.mkdir()
        xcode = tools / "xcodebuild"
        xcode.write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
pathlib.Path(os.environ['ARGS_FILE']).write_text(json.dumps(args))
if os.environ['CREATE_BUNDLE'] == '1':
    result = pathlib.Path(args[args.index('-resultBundlePath') + 1])
    result.mkdir()
    (result / 'assertion.txt').write_text('synthetic failed assertion')
sys.exit(int(os.environ['TEST_EXIT']))
""")
        xcode.chmod(0o755)
        xcrun = tools / "xcrun"
        xcrun.write_text("""#!/usr/bin/env python3
import json, os, sys
print(json.dumps({'synthetic': True, 'kind': sys.argv[4]}))
sys.exit(int(os.environ['EXPORT_EXIT']))
""")
        xcrun.chmod(0o755)
        output = root / "preserved results"
        if blocked_output:
            output.write_text("not a directory")
        result = root / "ios-ui-tests.xcresult"
        args_file = root / "args.json"
        env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                   TEST_EXIT=str(test_exit), CREATE_BUNDLE=str(int(create_bundle)),
                   EXPORT_EXIT=str(export_exit), ARGS_FILE=str(args_file),
                   ORBITTERM_APPLE_TEST_RESULTS_DIR=str(output))
        process = subprocess.run(["bash", str(RUNNER), str(result), "test", "-quiet",
                                  "-destination", "platform=iOS Simulator,name=Test Device"],
                                 env=env, text=True, capture_output=True)
        return process, output, json.loads(args_file.read_text())

    def test_failed_test_preserves_assertions_and_original_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            process, output, args = self.run_fixture(Path(directory), test_exit=65)
            self.assertEqual(process.returncode, 65)
            self.assertEqual((output / "ios-ui-tests.xcresult/assertion.txt").read_text(),
                             "synthetic failed assertion")
            self.assertTrue((output / "ios-ui-tests-summary.json").is_file())
            self.assertTrue((output / "ios-ui-tests-tests.json").is_file())
            self.assertEqual(args[:4], ["test", "-quiet", "-destination",
                                       "platform=iOS Simulator,name=Test Device"])

    def test_success_without_a_bundle_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            process, output, _ = self.run_fixture(Path(directory), create_bundle=False)
            self.assertNotEqual(process.returncode, 0)
            self.assertFalse(output.exists())

    def test_export_failure_does_not_hide_test_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            process, _, _ = self.run_fixture(Path(directory), test_exit=65, export_exit=9)
            self.assertEqual(process.returncode, 65)

    def test_preservation_failure_fails_an_otherwise_successful_run(self):
        with tempfile.TemporaryDirectory() as directory:
            process, _, _ = self.run_fixture(Path(directory), blocked_output=True)
            self.assertNotEqual(process.returncode, 0)

    def test_success_preserves_result_and_exits_zero(self):
        with tempfile.TemporaryDirectory() as directory:
            process, output, _ = self.run_fixture(Path(directory))
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertTrue((output / "ios-ui-tests.xcresult/assertion.txt").is_file())


if __name__ == "__main__":
    unittest.main()
