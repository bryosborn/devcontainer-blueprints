"""Minimal identity setup must support independently selected local tools."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class BaseIdentityTests(unittest.TestCase):
    def test_root_identity_prepares_python_install_without_other_components(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            identity = (ROOT / "src/components/base/identity.sh").read_text()
            configure = (ROOT / "src/components/base/configure-tools.sh").read_text()
            # Use a disposable prefix and the caller's ownership. Directory
            # creation and the full Python configuration logic run unchanged.
            for original in ("/usr/local", "/opt", "/workspaces"):
                replacement = str(root / original.lstrip("/"))
                identity = identity.replace(original, replacement)
                configure = configure.replace(original, replacement)
            identity = identity.replace("-o root -g root", f"-o {os.getuid()} -g {os.getgid()}")
            subprocess.run(["sh", "-c", identity, "identity", "root", "0", "0", "false"],
                           check=True, capture_output=True, text=True)
            local_bin = root / "usr/local/bin"
            self.assertEqual(local_bin.stat().st_mode & 0o777, 0o755)
            fixture_bin = root / "fixture-bin"
            fixture_bin.mkdir()
            for name in ("python3.13", "pip3.13"):
                executable = fixture_bin / name
                executable.write_text("#!/bin/sh\nexit 0\n")
                executable.chmod(0o755)
            subprocess.run(["sh", "-c", configure, "configure", "--python-versions", "3.13"],
                           env={**os.environ, "PATH": f"{fixture_bin}:{os.environ['PATH']}"},
                           check=True, capture_output=True, text=True)
            self.assertEqual((local_bin / "python3").resolve(), fixture_bin / "python3.13")
            self.assertEqual((local_bin / "pip3").resolve(), fixture_bin / "pip3.13")


if __name__ == "__main__":
    unittest.main()
