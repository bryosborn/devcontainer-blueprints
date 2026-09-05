"""Extension installation stays within the selected archive or explicit lock paths."""
import hashlib
import json
import os
from pathlib import Path
import pwd
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
INSTALLER = ROOT / "src/wolfi/components/vscode/install-extensions.sh"


class ExtensionInstallationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.user = pwd.getpwuid(os.getuid()).pw_name
        self.record = self.root / "installed.json"
        self.fake_bin = self.root / "bin"
        self.fake_bin.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.staging = self.root / "staging"
        self.staging.mkdir()
        getent = self.fake_bin / "getent"
        getent.write_text(f"#!/bin/sh\nprintf '%s\\n' '{self.user}:x:{os.getuid()}:{os.getgid()}::{self.home}:/bin/bash'\n")
        getent.chmod(0o755)
        self.code = self.fake_bin / "code-server"
        self.code.write_text('''#!/usr/bin/env python3
import json,os,pathlib,sys
if '--install-extension' in sys.argv:
    source=pathlib.Path(sys.argv[sys.argv.index('--install-extension')+1])
    pathlib.Path(os.environ['WOLFI_INSTALL_RECORD']).write_text(json.dumps({'path':str(source),'bytes':source.read_text()}))
elif '--list-extensions' in sys.argv:
    print('Publisher.Fixture@1.2.3')
''')
        self.code.chmod(0o755)
        # Keep test-only user data and output manifests out of shared /tmp.
        self.installer = self.root / "install-extensions.sh"
        source = INSTALLER.read_text()
        for name in ("vscode-server-user-data", "vscode-installed-extensions.txt"):
            source = source.replace("/tmp/" + name, str(self.root / name))
        self.installer.write_text(source)
        self.content = b"selected archive VSIX bytes\n"
        self.decoy = self.root / "shared-cache/same-name.vsix"
        self.decoy.parent.mkdir()
        self.decoy.write_bytes(self.content)
        self.lock_data = {
            "targetVscodeCommit": "a" * 40,
            "containerInstallOrder": ["Publisher.Fixture"], "hostOnlyExtensions": [],
            "extensions": {"Publisher.Fixture": {
                "version": "1.2.3", "vsixPath": str(self.decoy),
                "sha256": hashlib.sha256(self.content).hexdigest(),
            }},
        }

    def invoke(self, *arguments):
        return subprocess.run(["bash", str(self.installer), *arguments,
                               "--user", self.user, "--code-server", str(self.code),
                               "--extensions-dir", str(self.home / "extensions"),
                               "--client-output", str(self.home / "client")],
                              env={**os.environ, "PATH": f"{self.fake_bin}:{os.environ['PATH']}",
                                   "TMPDIR": str(self.staging), "WOLFI_INSTALL_RECORD": str(self.record)},
                              cwd=self.root, capture_output=True, text=True)

    def archive(self, include_server=True):
        payload = self.root / "archive-source/vscode-extensions"
        (payload / "client").mkdir(parents=True)
        lock = payload / "vscode-extensions.lock.json"
        lock.write_text(json.dumps(self.lock_data))
        checksums = [f"{hashlib.sha256(lock.read_bytes()).hexdigest()}  {lock.name}\n"]
        if include_server:
            relative = "server/publisher.fixture/1.2.3/same-name.vsix"
            file = payload / relative
            file.parent.mkdir(parents=True)
            file.write_bytes(self.content)
            checksums.append(f"{hashlib.sha256(self.content).hexdigest()}  {relative}\n")
        (payload / "SHA256SUMS").write_text("".join(checksums))
        archive = self.root / "extensions.tar.gz"
        with tarfile.open(archive, "w:gz") as output:
            output.add(payload, arcname="vscode-extensions")
        Path(str(archive) + ".sha256").write_text(f"{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}\n")
        return archive

    def test_archive_uses_its_own_bytes_even_when_original_path_exists(self):
        archive = self.archive()
        self.decoy.write_text("different bytes at the original source path")
        result = self.invoke("--archive", str(archive))
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = json.loads(self.record.read_text())
        self.assertEqual(installed["bytes"], self.content.decode())
        self.assertTrue(installed["path"].startswith(str(self.staging) + "/"))
        self.assertTrue(installed["path"].endswith("/vscode-extensions/server/publisher.fixture/1.2.3/same-name.vsix"))

    def test_missing_archive_member_cannot_use_matching_external_bytes(self):
        result = self.invoke("--archive", str(self.archive(include_server=False)))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("VSIX not found", result.stderr)
        self.assertFalse(self.record.exists())

    def test_archive_member_must_match_the_lock_hash(self):
        self.lock_data["extensions"]["Publisher.Fixture"]["sha256"] = "0" * 64
        result = self.invoke("--archive", str(self.archive()))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA256 mismatch", result.stderr)
        self.assertFalse(self.record.exists())

    def test_unpacked_lock_uses_exact_relative_path_and_rejects_basename_search(self):
        lock = self.root / "unpacked/extensions.lock.json"
        lock.parent.mkdir()
        self.lock_data["extensions"]["Publisher.Fixture"]["vsixPath"] = "nested/same-name.vsix"
        lock.write_text(json.dumps(self.lock_data))
        exact = lock.parent / "nested/same-name.vsix"
        exact.parent.mkdir()
        exact.write_bytes(self.content)
        result = self.invoke("--lock", str(lock))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.record.read_text())["path"], str(exact))
        exact.rename(lock.parent / "same-name.vsix")
        self.record.unlink()
        result = self.invoke("--lock", str(lock))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("VSIX not found", result.stderr)
        self.assertFalse(self.record.exists())


if __name__ == "__main__":
    unittest.main()
