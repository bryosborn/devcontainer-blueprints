#!/usr/bin/env python3
"""Regression tests for split scan, transfer, cleanup, and profile boundaries."""

from __future__ import annotations

import argparse
import copy
import hashlib
import io
import json
import os
import shutil
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from src.cli import cleanup, transfer
from src.core.hashing import sha256, write_json
from src.core.profile import CONFIG_LABEL, LOCK_LABEL, SETTINGS_LABEL, Profile, WorkflowError, load_settings, relative_path
from src.scan import command as scan_command

REPO = Path(__file__).resolve().parents[2]


def save_image(path: Path, reference: str, labels: dict[str, str], architecture: str = "amd64") -> str:
    config = json.dumps({"os": "linux", "architecture": architecture, "config": {"Labels": labels}}).encode()
    digest = hashlib.sha256(config).hexdigest()
    manifest = json.dumps([{"Config": digest + ".json", "RepoTags": [reference], "Layers": []}]).encode()
    path.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(path, "w") as archive:
        for name, data in ((digest + ".json", config), ("manifest.json", manifest)):
            info = tarfile.TarInfo(name)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
    return "sha256:" + digest


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name)
        (self.repo / "config").mkdir()
        self.settings_path = self.repo / "config/images.env"
        self.settings_path.write_text("IMAGE_PREFIX=local\nIMAGE_FAMILY=toolbox\nIMAGE_VERSION=0.2.0\nIMAGE_PROFILES=dev,build,kaniko\n")
        self.config = self.repo / "config/dev.yaml"
        self.config.write_text("schemaVersion: 3\nprofile: dev\n")
        self.root = self.repo / "artifacts/dev"
        self.image = "local/toolbox-dev:0.2.0"
        self.base_ref = "local/base:locked"
        self.base_labels = {"devcontainers.wolfi.base.digest": "sha256:" + "a" * 64,
                            "devcontainers.wolfi.base.source": "example/base@sha256:" + "a" * 64}
        self.base_path = self.root / "linux-amd64/docker-images/base.tar"
        self.base_id = save_image(self.base_path, self.base_ref, self.base_labels)
        self.apk = self.root / "linux-amd64/apk/repositories/main/x86_64/test.apk"
        self.apk.parent.mkdir(parents=True)
        self.apk.write_bytes(b"locked APK bytes")
        base = {"artifactDirectory": "artifacts/dev/linux-amd64", "file": "docker-images/base.tar",
                "sha256": sha256(self.base_path), "localReference": self.base_ref,
                "digest": self.base_labels["devcontainers.wolfi.base.digest"],
                "pinnedReference": self.base_labels["devcontainers.wolfi.base.source"]}
        self.lock = {
            "schemaVersion": 3,
            "source": {"fileSha256": sha256(self.config), "settingsFileSha256": sha256(self.settings_path)},
            "image": {"reference": self.image, "platform": "linux/amd64"},
            "config": {"profile": "dev", "artifacts": {"root": "artifacts/dev"}},
            "resolved": {"apk": {"artifactDirectory": "artifacts/dev/linux-amd64/apk", "repositories": {}, "keys": [],
                                   "packages": [{"file": "repositories/main/x86_64/test.apk", "sha256": sha256(self.apk)}],
                                   "baseImage": {"artifact": base}}},
        }
        self.lock_path = self.repo / "config/dev.lock.json"
        self.refresh_profile()
        self.args = argparse.Namespace(output=None, output_dir=None, cache_dir=None, skip_db_download=False,
                                       skip_acceptance_gate=False, include_vsix_archive=False,
                                       docker_images=False, dry_run=False)

    def refresh_profile(self):
        self.lock_path.write_text(json.dumps(self.lock))
        self.profile = Profile("dev", self.repo)
        self.labels = {LOCK_LABEL: self.profile.digest, CONFIG_LABEL: self.lock["source"]["fileSha256"],
                       SETTINGS_LABEL: self.lock["source"]["settingsFileSha256"]}
        self.output_template = self.repo / "output-image.tar"
        self.image_id = save_image(self.output_template, self.image, self.labels)
        self.identity = {"Id": self.image_id, "Os": "linux", "Architecture": "amd64", "Size": 1234,
                         "Config": {"Labels": self.labels}}

    def inspect(self, reference=None):
        if reference is None:
            return self.identity
        return {"Id": self.base_id, "Os": "linux", "Architecture": "amd64", "Config": {"Labels": self.base_labels}}

    def docker(self, *arguments, **kwargs):
        if arguments[:3] == ("docker", "image", "save"):
            shutil.copyfile(self.output_template, arguments[arguments.index("--output") + 1])
        return argparse.Namespace(returncode=0, stdout="")

    def package(self):
        with patch.object(self.profile, "verify"), patch.object(self.profile, "inspect", side_effect=self.inspect), \
                patch.object(transfer, "run", side_effect=self.docker):
            transfer.package(self.profile, self.args)

    def manifest(self):
        return self.root / "transfer/manifest.json"

    def test_bundle_is_profile_scoped_and_binds_settings(self):
        other = self.repo / "artifacts/build/private"
        other.parent.mkdir(parents=True)
        other.write_text("other profile")
        self.package()
        bundle = self.repo / "artifacts-dev-linux-amd64.tar.gz"
        with tarfile.open(bundle) as archive:
            names = set(archive.getnames())
        self.assertTrue({"config/dev.yaml", "config/dev.lock.json", "config/images.env",
                         "artifacts/dev/transfer/image.tar", str(self.apk.relative_to(self.repo))} <= names)
        self.assertFalse(any("private" in name for name in names))
        manifest = json.loads(self.manifest().read_text())
        self.assertEqual(manifest["schemaVersion"], 3)
        self.assertEqual(manifest["settingsSha256"], sha256(self.settings_path))

    def test_package_rejects_changed_locked_bytes_before_docker(self):
        self.apk.write_text("changed")
        with patch.object(self.profile, "verify"), patch.object(transfer, "run") as docker:
            with self.assertRaisesRegex(WorkflowError, "changed"):
                transfer.package(self.profile, self.args)
        docker.assert_not_called()

    def test_load_rejects_tampered_payload_and_manifest_before_docker(self):
        self.package()
        original = self.apk.read_bytes()
        self.apk.write_bytes(original + b"tampered")
        with patch.object(self.profile, "verify"), patch.object(transfer, "run") as docker:
            with self.assertRaisesRegex(WorkflowError, "changed"):
                transfer.load(self.profile, self.args)
        docker.assert_not_called()
        self.apk.write_bytes(original)
        manifest = json.loads(self.manifest().read_text())
        manifest["settingsSha256"] = "0" * 64
        write_json(self.manifest(), manifest)
        with patch.object(self.profile, "verify"), patch.object(transfer, "run") as docker:
            with self.assertRaisesRegex(WorkflowError, "differs"):
                transfer.load(self.profile, self.args)
        docker.assert_not_called()

    def test_load_rejects_tampered_saved_image_label(self):
        self.package()
        manifest = json.loads(self.manifest().read_text())
        image_tar = self.repo / manifest["imageTar"]
        save_image(image_tar, self.image, {**self.labels, SETTINGS_LABEL: "0" * 64})
        manifest["files"][manifest["imageTar"]] = sha256(image_tar)
        write_json(self.manifest(), manifest)
        with patch.object(self.profile, "verify"), patch.object(transfer, "run") as docker:
            with self.assertRaisesRegex(WorkflowError, "different lock or base"):
                transfer.load(self.profile, self.args)
        docker.assert_not_called()

    def test_restore_loads_only_verified_base_and_output(self):
        self.package()
        with patch.object(self.profile, "verify"), patch.object(self.profile, "inspect", side_effect=self.inspect), \
                patch.object(transfer, "run", side_effect=self.docker) as docker:
            transfer.load(self.profile, self.args)
        self.assertEqual([call.args[:2] for call in docker.call_args_list], [("docker", "load"), ("docker", "load")])

    def test_archive_rejects_wrong_platform(self):
        save_image(self.output_template, self.image, self.labels, "arm64")
        with self.assertRaisesRegex(WorkflowError, "platform"):
            transfer.archive_identity(self.output_template, self.image, self.profile.platform, self.labels)

    def test_paths_cannot_escape_or_use_symlinks(self):
        for value in ("../escape", "/absolute", "artifacts/../config", "artifacts//dev"):
            with self.subTest(value=value), self.assertRaises(WorkflowError):
                relative_path(self.repo, value)
        (self.repo / "link").symlink_to(self.config)
        with self.assertRaises(WorkflowError):
            relative_path(self.repo, "link")

    def test_cleanup_is_profile_scoped_and_dry_run_safe(self):
        other = self.repo / "artifacts/build/retain"
        other.parent.mkdir(parents=True)
        other.write_text("retain")
        self.args.dry_run = True
        with patch.object(self.profile, "verify"):
            cleanup.clean(self.profile, self.args)
        self.assertTrue(self.apk.exists())
        self.args.dry_run = False
        with patch.object(self.profile, "verify"):
            cleanup.clean(self.profile, self.args)
        self.assertFalse(self.root.exists())
        self.assertTrue(other.exists())

    def install_fake_scanner(self):
        scanner = self.repo / "src/scan"
        scanner.mkdir(parents=True)
        shutil.copy(REPO / "src/scan/trivy.sh", scanner / "trivy.sh")
        shutil.copy(REPO / "src/scan/summarize.py", scanner / "summarize.py")
        binaries = self.repo / "bin"
        binaries.mkdir()
        (binaries / "docker").write_text('''#!/usr/bin/env python3
import json,os,sys
identity=json.loads(os.environ['FAKE_IDENTITY'])
if '--format' in sys.argv: print(identity['Id'])
else: print(json.dumps([identity]))
''')
        (binaries / "trivy").write_text('''#!/usr/bin/env python3
import json,os,sys
assert not any(key.startswith('TRIVY_') for key in os.environ)
args=sys.argv[1:]
context={'Version':'test','VulnerabilityDB':{'Version':2,'UpdatedAt':'2026-01-01'},'JavaDB':{'Version':1,'UpdatedAt':'2026-01-01'}}
if args[0]=='version': print(json.dumps(context)); sys.exit()
if '--download-db-only' in args or '--download-java-db-only' in args: sys.exit()
for option in ('--skip-db-update','--skip-java-db-update','--offline-scan','--ignore-unfixed=false'): assert option in args
image=args[-1]; identity=json.loads(os.environ['FAKE_IDENTITY'])
if args[args.index('--format')+1]=='json':
 findings=[{'VulnerabilityID':'CVE-TEST','Severity':'HIGH','PkgName':'test','InstalledVersion':'1'}] if os.environ.get('FAKE_HIGH')=='1' else []
 value={'ArtifactName':image,'Metadata':{'ImageID':identity['Id']},'Results':[{'Target':'test','Vulnerabilities':findings}]}
else:
 value={'bomFormat':'CycloneDX','components':[],'metadata':{'component':{'name':image,'properties':[{'name':'aquasecurity:trivy:ImageID','value':identity['Id']}]}}}
with open(args[args.index('--output')+1],'w') as output: json.dump(value,output)
''')
        for path in binaries.iterdir():
            path.chmod(0o755)
        return {"PATH": str(binaries) + ":" + os.environ["PATH"], "FAKE_IDENTITY": json.dumps(self.identity),
                "TRIVY_SEVERITY": "LOW", "TRIVY_IGNORE_UNFIXED": "true"}

    def scan_output(self):
        return self.profile.platform_root / "reports/scan"

    def test_raw_scan_binds_sbom_and_fails_high_findings(self):
        environment = self.install_fake_scanner()
        with patch.dict(os.environ, environment), patch.object(self.profile, "verify"), patch.object(self.profile, "inspect", return_value=self.identity):
            scan_command.scan(self.profile, self.args)
        metadata, _, counts = scan_command.verify_scan(self.profile, self.scan_output())
        self.assertEqual(counts["HIGH"], 0)
        self.assertEqual(metadata["settingsSha256"], sha256(self.settings_path))
        with patch.dict(os.environ, {**environment, "FAKE_HIGH": "1"}), patch.object(self.profile, "verify"), patch.object(self.profile, "inspect", return_value=self.identity):
            with self.assertRaisesRegex(WorkflowError, "1 High"):
                scan_command.scan(self.profile, self.args)
        self.assertIs(json.loads((self.scan_output() / "acceptance.json").read_text())["passed"], False)

    def test_stale_image_invalidates_previous_pass_first(self):
        self.scan_output().mkdir(parents=True)
        (self.scan_output() / "report.md").write_text("PASS")
        with patch.object(self.profile, "verify"), patch.object(self.profile, "inspect", side_effect=WorkflowError("stale")):
            with self.assertRaisesRegex(WorkflowError, "stale"):
                scan_command.scan(self.profile, self.args)
        self.assertFalse((self.scan_output() / "report.md").exists())


class SettingsTests(unittest.TestCase):
    def test_python_settings_parser_never_evaluates_shell(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            (repo / "config").mkdir()
            marker = repo / "executed"
            (repo / "config/images.env").write_text(
                f"IMAGE_PREFIX=$(touch${{IFS}}{marker})\nIMAGE_FAMILY=toolbox\nIMAGE_VERSION=1\nIMAGE_PROFILES=dev\n"
            )
            with self.assertRaises(WorkflowError):
                load_settings(repo)
            self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
