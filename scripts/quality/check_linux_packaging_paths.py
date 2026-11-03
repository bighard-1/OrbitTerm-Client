#!/usr/bin/env python3
"""Exercise release artifact ownership and XDG installation paths without installing."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[2] / "clients/linux/scripts"


class PackagingPaths(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="orbitterm-package-paths-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.linux = self.root / "source with spaces/clients/linux"
        self.scripts = self.linux / "scripts"
        self.scripts.mkdir(parents=True)
        for name in ("build_release.sh", "build_deb.sh", "install_flatpak.sh"):
            shutil.copy2(SCRIPTS / name, self.scripts / name)
        self.commands = self.root / "commands"
        self.commands.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        (self.home / ".cargo").mkdir()
        (self.home / ".cargo/env").write_text("")
        self.env = dict(os.environ, HOME=str(self.home),
                        PATH=str(self.commands) + os.pathsep + os.environ["PATH"])
        for key in ("CARGO_TARGET_DIR", "CARGO_BUILD_TARGET", "FLATPAK_USER_DIR",
                    "XDG_DATA_HOME", "XDG_CONFIG_HOME"):
            self.env.pop(key, None)
        self.binary = self.root / "external cache/aarch64-unknown-linux-gnu/release/orbitterm-linux"
        self.binary.parent.mkdir(parents=True)
        self.binary.write_text("#!/bin/sh\nexit 0\n")
        self.binary.chmod(0o755)
        # A stale default artifact must never be used as a fallback.
        stale = self.linux / "target/release/orbitterm-linux"
        stale.parent.mkdir(parents=True)
        stale.write_text("#!/bin/sh\nexit 99\n")
        stale.chmod(0o755)
        self.env["QA_ARTIFACTS"] = json.dumps([self.artifact(self.binary)])
        self.command("cargo", """#!/usr/bin/env python3
import json, os, sys
for artifact in json.loads(os.environ['QA_ARTIFACTS']):
    print(json.dumps(artifact))
sys.exit(int(os.environ.get('QA_CARGO_EXIT', '0')))
""")

    def command(self, name, text):
        path = self.commands / name
        path.write_text(text)
        path.chmod(0o755)

    @staticmethod
    def artifact(path):
        return {"reason": "compiler-artifact", "target": {
            "name": "orbitterm-linux", "kind": ["bin"]}, "executable": str(path)}

    def release(self):
        return subprocess.run(["bash", str(self.scripts / "build_release.sh"),
                               "--print-binary-path"], env=self.env,
                              text=True, capture_output=True, check=False)

    def test_uses_current_cargo_artifact_in_external_target_directory(self):
        result = self.release()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(self.binary))

    def test_missing_artifact_does_not_use_stale_default(self):
        self.env["QA_ARTIFACTS"] = "[]"
        self.assertNotEqual(self.release().returncode, 0)

    def test_ambiguous_artifacts_are_rejected(self):
        self.env["QA_ARTIFACTS"] = json.dumps([
            self.artifact(self.binary), self.artifact(self.binary.with_name("other"))])
        self.assertNotEqual(self.release().returncode, 0)

    def test_failed_build_cannot_publish_even_a_valid_artifact(self):
        self.env["QA_CARGO_EXIT"] = "7"
        self.assertNotEqual(self.release().returncode, 0)

    def test_debian_package_rejects_a_binary_for_another_architecture(self):
        header = bytearray(20)
        header[:6] = b"\x7fELF\x02\x01"
        header[18:20] = (183).to_bytes(2, "little")  # AArch64, not amd64.
        self.binary.write_bytes(header)
        result = subprocess.run(["bash", str(self.scripts / "build_deb.sh")], env=self.env,
                                text=True, capture_output=True, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("amd64", result.stderr)

    @unittest.skipUnless(sys.platform == "linux", "Flatpak installer requires GNU install")
    def test_flatpak_exports_and_launchers_follow_xdg_and_custom_installation(self):
        data = self.root / "xdg data"
        installation = self.root / "flatpak installation"
        exports = installation / "exports/share"
        desktop = exports / "applications/com.orbitterm.Client.desktop"
        icon = exports / "icons/hicolor/512x512/apps/com.orbitterm.Client.png"
        desktop.parent.mkdir(parents=True)
        icon.parent.mkdir(parents=True)
        desktop.write_text("[Desktop Entry]\nType=Application\nName=OrbitTerm\n")
        icon.write_bytes(b"virtual-icon")
        bundle = self.root / "virtual.flatpak"
        bundle.write_bytes(b"virtual-bundle")
        self.env.update(XDG_DATA_HOME=str(data), FLATPAK_USER_DIR=str(installation))
        self.command("flatpak", "#!/bin/sh\nexit 0\n")
        self.command("xdg-user-dir", "#!/bin/sh\nprintf '%s\\n' \"$HOME\"\n")
        for name in ("update-desktop-database", "gtk-update-icon-cache"):
            self.command(name, "#!/bin/sh\nexit 0\n")
        result = subprocess.run(["bash", str(self.scripts / "install_flatpak.sh"), str(bundle)],
                                env=self.env, text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((data / "applications" / desktop.name).read_bytes(), desktop.read_bytes())
        self.assertEqual((data / "icons/hicolor/512x512/apps" / icon.name).read_bytes(), icon.read_bytes())
        self.assertFalse((self.home / ".local/share/applications").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
