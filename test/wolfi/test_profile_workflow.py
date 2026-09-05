#!/usr/bin/env python3
"""Offline regression tests for profile scans, transfer boundaries, and cleanup."""

import argparse
import copy
import hashlib
import importlib.util
import io
import json
import os
import shutil
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("workflow", REPO / "scripts/wolfi/workflow.py")
w = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(w)


def save_image(path, reference, labels, architecture="amd64"):
    config = json.dumps({"os": "linux", "architecture": architecture,
                         "config": {"Labels": labels}}).encode()
    digest = hashlib.sha256(config).hexdigest()
    manifest = json.dumps([{"Config": digest + ".json", "RepoTags": [reference], "Layers": []}]).encode()
    path.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(path, "w") as archive:
        for name, data in ((digest + ".json", config), ("manifest.json", manifest)):
            info = tarfile.TarInfo(name)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
    return "sha256:" + digest


def add_oci_index(path, config_id, wrong_attestation=False):
    with tarfile.open(path, "a") as archive:
        def add(name, value):
            data = json.dumps(value).encode()
            if name is None:
                digest = hashlib.sha256(data).hexdigest()
                name = "blobs/sha256/" + digest
            info = tarfile.TarInfo(name)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
            return {"digest": "sha256:" + hashlib.sha256(data).hexdigest(), "size": len(data)}
        image = add(None, {"config": {"digest": config_id}})
        image["platform"] = {"os": "linux", "architecture": "amd64"}
        attestation = add(None, {"subject": {"digest": image["digest"]}})
        attestation["annotations"] = {"vnd.docker.reference.type": "attestation-manifest",
                                      "vnd.docker.reference.digest": "sha256:" + "0" * 64 if wrong_attestation else image["digest"]}
        index = add(None, {"manifests": [image, attestation]})
        add("index.json", {"manifests": [index]})
        return index["digest"]


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name)
        self.root = self.repo / "artifacts/wolfi/ci"
        self.config = self.repo / "config/wolfi-ci.yaml"
        self.lock_path = self.config.with_suffix(".lock.json")
        self.config.parent.mkdir()
        self.config.write_text("schemaVersion: 2\n")
        self.image = "example/ci:1"
        self.base_ref = "example/base:locked"
        self.base_labels = {"devcontainers.wolfi.base.digest": "sha256:" + "a" * 64,
                            "devcontainers.wolfi.base.source": "example/base@sha256:" + "a" * 64}
        self.base_path = self.root / "linux-amd64/docker-images/base.tar"
        self.base_id = save_image(self.base_path, self.base_ref, self.base_labels)
        self.apk = self.root / "linux-amd64/apk/repositories/main/x86_64/test.apk"
        self.apk.parent.mkdir(parents=True)
        self.apk.write_bytes(b"locked APK bytes")
        base = {"artifactDirectory": "artifacts/wolfi/ci/linux-amd64", "file": "docker-images/base.tar",
                "sha256": w.sha256(self.base_path), "localReference": self.base_ref,
                "digest": self.base_labels["devcontainers.wolfi.base.digest"],
                "pinnedReference": self.base_labels["devcontainers.wolfi.base.source"]}
        self.lock = {"schemaVersion": 2, "image": {"reference": self.image, "platform": "linux/amd64"},
                     "config": {"artifacts": {"root": "artifacts/wolfi/ci"}},
                     "resolved": {"apk": {"artifactDirectory": "artifacts/wolfi/ci/linux-amd64/apk",
                                          "repositories": {}, "keys": [],
                                          "packages": [{"file": "repositories/main/x86_64/test.apk", "sha256": w.sha256(self.apk)}],
                                          "baseImage": {"artifact": base}}}}
        self.refresh_profile()
        self.args = argparse.Namespace(output=None, output_dir=None, cache_dir=None,
                                       skip_db_download=False, skip_acceptance_gate=False,
                                       include_vsix_archive=False, docker_images=False, dry_run=False)

    def refresh_profile(self):
        self.lock_path.write_text(json.dumps(self.lock))
        self.profile = w.Profile(self.config, self.lock_path, self.repo)
        self.output_template = self.repo / "output-image.tar"
        self.image_id = save_image(self.output_template, self.image, {w.LOCK_LABEL: self.profile.digest})
        self.identity = {"Id": self.image_id, "Os": "linux", "Architecture": "amd64", "Size": 1234,
                         "Config": {"Labels": {w.LOCK_LABEL: self.profile.digest}}}

    def inspect(self, reference=None):
        if reference is None:
            return self.identity
        return {"Id": self.base_id, "Os": "linux", "Architecture": "amd64", "Config": {"Labels": self.base_labels}}

    def docker(self, *arguments, **kwargs):
        if arguments[:3] == ("docker", "image", "save"):
            shutil.copyfile(self.output_template, arguments[arguments.index("--output") + 1])
        return argparse.Namespace(returncode=0, stdout="")

    def package(self):
        with patch.object(self.profile, "verify"), patch.object(self.profile, "inspect", side_effect=self.inspect), patch.object(w, "run", side_effect=self.docker):
            w.package(self.profile, self.args)

    def manifest(self):
        return self.root / "transfer/manifest.json"

    def test_bundle_contains_only_selected_locked_payload(self):
        other = self.repo / "artifacts/wolfi/dev/private"
        other.parent.mkdir(parents=True)
        other.write_text("other profile")
        cache = self.root / "linux-amd64/trivy-cache/unrelated"
        cache.parent.mkdir()
        cache.write_text("cache")
        self.package()
        bundle = self.repo / "artifacts-wolfi-ci-linux-amd64.tar.gz"
        with tarfile.open(bundle) as archive:
            names = set(archive.getnames())
        self.assertIn("config/wolfi-ci.yaml", names)
        self.assertIn("config/wolfi-ci.lock.json", names)
        self.assertIn("artifacts/wolfi/ci/transfer/image.tar", names)
        self.assertIn(str(self.apk.relative_to(self.repo)), names)
        self.assertFalse(any("private" in name or "trivy-cache" in name for name in names))

    def select_optional_vendor_fixtures(self):
        """Represent every transferred file shape from both optional vendors."""
        records = []

        def artifact(relative, **metadata):
            path = self.root / "linux-amd64/vendor" / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(f"locked {relative} fixture".encode())
            record = {"file": str(path.relative_to(self.repo)),
                      "sha256": w.sha256(path), "size": path.stat().st_size,
                      **metadata}
            records.append(record)
            return record

        self.lock["config"]["kaniko"] = {"version": "1.28.4"}
        self.lock["resolved"]["kaniko"] = {
            "version": "1.28.4", "platform": "linux/amd64",
            "archive": artifact("kaniko/kaniko.tar.gz"),
            "signature": artifact("kaniko/signature-verification.json"),
            "sources": [artifact(f"kaniko/source/{kind}", kind=kind)
                        for kind in ("index", "manifest", "config", "layer")],
        }
        self.lock["config"]["playwright"] = {"version": "1.63.0"}
        self.lock["config"]["build"] = {"node": "24", "npm": "12"}
        self.lock["resolved"]["playwright"] = {
            "version": "1.63.0", "platform": "linux/amd64",
            "archive": artifact("playwright/browsers.tar.gz"),
            "testRunner": artifact("playwright/test-runner.tar.gz"),
            "packages": [artifact(f"playwright/npm/{filename}.tgz", name=name)
                         for filename, name in (("test", "@playwright/test"),
                                                ("playwright", "playwright"),
                                                ("core", "playwright-core"))],
            "browsers": [artifact(f"playwright/downloads/{name}.zip", name=name)
                         for name in ("chromium", "chromium-headless-shell")],
        }
        self.refresh_profile()
        return records

    def test_optional_vendor_bundle_contains_every_locked_file_and_loads(self):
        records = self.select_optional_vendor_fixtures()
        self.package()
        manifest = w.read_json(self.manifest())
        bundle = self.repo / "artifacts-wolfi-ci-linux-amd64.tar.gz"
        with tarfile.open(bundle) as archive:
            for record in records:
                with self.subTest(file=record["file"]):
                    self.assertEqual(manifest["files"][record["file"]], record["sha256"])
                    data = archive.extractfile(record["file"]).read()
                    self.assertEqual(hashlib.sha256(data).hexdigest(), record["sha256"])
        with patch.object(self.profile, "verify"), patch.object(self.profile, "inspect", side_effect=self.inspect), patch.object(w, "run", side_effect=self.docker) as docker:
            w.load(self.profile, self.args)
        self.assertEqual([call.args[:2] for call in docker.call_args_list],
                         [("docker", "load"), ("docker", "load")])

    def test_optional_vendor_load_rejects_each_omitted_manifest_entry_before_docker(self):
        records = self.select_optional_vendor_fixtures()
        self.package()
        original = w.read_json(self.manifest())
        for record in records:
            manifest = copy.deepcopy(original)
            del manifest["files"][record["file"]]
            w.write_json(self.manifest(), manifest)
            with self.subTest(file=record["file"]), patch.object(self.profile, "verify"), patch.object(w, "run") as docker:
                with self.assertRaisesRegex(w.WorkflowError, "omits or alters"):
                    w.load(self.profile, self.args)
                docker.assert_not_called()

    def test_optional_vendor_load_rejects_tampered_bytes_before_docker(self):
        records = self.select_optional_vendor_fixtures()
        self.package()
        for record in records:
            path = self.repo / record["file"]
            original = path.read_bytes()
            path.write_bytes(original + b"tampered")
            with self.subTest(file=record["file"]), patch.object(self.profile, "verify"), patch.object(w, "run") as docker:
                with self.assertRaisesRegex(w.WorkflowError, "changed"):
                    w.load(self.profile, self.args)
                docker.assert_not_called()
            path.write_bytes(original)

    def test_optional_vendor_load_rejects_cross_profile_records_before_docker(self):
        self.select_optional_vendor_fixtures()
        selected = [self.lock["resolved"]["kaniko"]["sources"][0],
                    self.lock["resolved"]["playwright"]["browsers"][0]]
        for record in selected:
            self.package()
            manifest = w.read_json(self.manifest())
            original_file = record["file"]
            other = self.repo / "artifacts/wolfi/dev/foreign-vendor"
            other.parent.mkdir(parents=True, exist_ok=True)
            other.write_bytes((self.repo / original_file).read_bytes())
            record["file"] = str(other.relative_to(self.repo))
            self.refresh_profile()
            manifest["lockSha256"] = self.profile.digest
            manifest["files"][str(self.lock_path.relative_to(self.repo))] = w.sha256(self.lock_path)
            w.write_json(self.manifest(), manifest)
            with self.subTest(file=original_file), patch.object(self.profile, "verify"), patch.object(w, "run") as docker:
                with self.assertRaisesRegex(w.WorkflowError, "outside this profile"):
                    w.load(self.profile, self.args)
                docker.assert_not_called()
            record["file"] = original_file
            self.refresh_profile()

    def test_package_rejects_changed_locked_artifact_before_docker(self):
        self.apk.write_text("changed")
        with patch.object(self.profile, "verify"), patch.object(w, "run") as docker:
            with self.assertRaisesRegex(w.WorkflowError, "changed"):
                w.package(self.profile, self.args)
        docker.assert_not_called()

    def test_restore_verifies_all_bytes_before_loading(self):
        self.package()
        self.apk.write_text("changed after packaging")
        with patch.object(self.profile, "verify"), patch.object(w, "run") as docker:
            with self.assertRaisesRegex(w.WorkflowError, "changed"):
                w.load(self.profile, self.args)
        docker.assert_not_called()

    def test_restore_rejects_missing_lock_artifact_in_manifest(self):
        self.package()
        manifest = w.read_json(self.manifest())
        del manifest["files"][str(self.apk.relative_to(self.repo))]
        w.write_json(self.manifest(), manifest)
        with patch.object(self.profile, "verify"), patch.object(w, "run") as docker:
            with self.assertRaisesRegex(w.WorkflowError, "omits"):
                w.load(self.profile, self.args)
        docker.assert_not_called()

    def test_restore_rejects_other_profile_and_wrong_platform(self):
        self.package()
        original = w.read_json(self.manifest())
        for key, value in (("image", "example/dev:1"), ("platform", "linux/arm64"), ("lockSha256", "0" * 64)):
            w.write_json(self.manifest(), {**original, key: value})
            with self.subTest(key=key), patch.object(self.profile, "verify"), patch.object(w, "run") as docker:
                with self.assertRaisesRegex(w.WorkflowError, "differs"):
                    w.load(self.profile, self.args)
                docker.assert_not_called()

    def test_restore_loads_only_base_and_output_and_verifies_ids(self):
        self.package()
        with patch.object(self.profile, "verify"), patch.object(self.profile, "inspect", side_effect=self.inspect), patch.object(w, "run", side_effect=self.docker) as docker:
            w.load(self.profile, self.args)
        self.assertEqual([call.args[:2] for call in docker.call_args_list], [("docker", "load"), ("docker", "load")])

    def test_restore_accepts_same_archive_across_docker_image_store_id_forms(self):
        config_id = self.image_id
        index_id = add_oci_index(self.output_template, config_id)
        self.identity["Id"] = index_id
        self.package()
        self.assertEqual(w.read_json(self.manifest())["imageId"], index_id)
        self.identity["Id"] = config_id
        with patch.object(self.profile, "verify"), patch.object(self.profile, "inspect", side_effect=self.inspect), patch.object(w, "run", side_effect=self.docker):
            w.load(self.profile, self.args)

    def test_tampered_saved_image_label_is_rejected_even_with_updated_manifest_hash(self):
        self.package()
        manifest = w.read_json(self.manifest())
        image_tar = self.repo / manifest["imageTar"]
        save_image(image_tar, self.image, {w.LOCK_LABEL: "0" * 64})
        manifest["files"][manifest["imageTar"]] = w.sha256(image_tar)
        w.write_json(self.manifest(), manifest)
        with patch.object(self.profile, "verify"), patch.object(w, "run") as docker:
            with self.assertRaisesRegex(w.WorkflowError, "different lock"):
                w.load(self.profile, self.args)
        docker.assert_not_called()

    def test_archive_rejects_wrong_platform(self):
        save_image(self.output_template, self.image, {w.LOCK_LABEL: self.profile.digest}, "arm64")
        with self.assertRaisesRegex(w.WorkflowError, "platform"):
            w.archive_identity(self.output_template, self.image, self.profile.platform, {w.LOCK_LABEL: self.profile.digest})

    def test_saved_containerd_index_with_buildkit_attestation_preserves_canonical_id(self):
        canonical = add_oci_index(self.output_template, self.image_id)
        ids = w.archive_identity(self.output_template, self.image, self.profile.platform, {w.LOCK_LABEL: self.profile.digest})
        self.assertIn(canonical, ids)
        self.assertIn(self.image_id, ids)

    def test_saved_containerd_index_rejects_unrelated_attestation(self):
        add_oci_index(self.output_template, self.image_id, wrong_attestation=True)
        with self.assertRaisesRegex(w.WorkflowError, "attestation refers"):
            w.archive_identity(self.output_template, self.image, self.profile.platform, {w.LOCK_LABEL: self.profile.digest})

    def test_paths_cannot_escape_or_use_symlinks(self):
        for value in ("../escape", "/absolute", "artifacts/../config", "artifacts//ci"):
            with self.subTest(value=value), self.assertRaises(w.WorkflowError):
                w.relative_path(self.repo, value)
        (self.repo / "link").symlink_to(self.config)
        with self.assertRaises(w.WorkflowError):
            w.relative_path(self.repo, "link")

    def test_cleanup_is_profile_scoped_and_dry_run_preserves_files(self):
        other = self.repo / "artifacts/wolfi/dev/retain"
        other.parent.mkdir(parents=True)
        other.write_text("retain")
        self.args.dry_run = True
        with patch.object(self.profile, "verify"):
            w.clean(self.profile, self.args)
        self.assertTrue(self.apk.exists())
        self.args.dry_run = False
        with patch.object(self.profile, "verify"):
            w.clean(self.profile, self.args)
        self.assertFalse(self.root.exists())
        self.assertTrue(other.exists())

    def test_cleanup_uses_validated_yaml_before_first_lock_and_after_drift(self):
        normalized = {"image": self.lock["image"], "artifacts": {"root": "artifacts/wolfi/ci"}}
        for missing in (True, False):
            self.refresh_profile()
            if missing:
                self.lock_path.unlink()
            with self.subTest(missing=missing), patch.object(w.Profile, "verify", side_effect=w.WorkflowError("drift")), patch.object(w, "run", return_value=argparse.Namespace(stdout=json.dumps(normalized))):
                selected = w.select_cleanup(self.config, self.lock_path, self.repo)
            self.assertIsInstance(selected, w.CleanSelection)
            self.assertEqual(selected.root, self.root)
            selected.verify()

    def test_extension_skip_tracks_installed_home_and_requires_archive(self):
        self.lock["config"]["vscode"] = {"version": "1"}
        self.refresh_profile()
        self.assertEqual(w.extension_archive_skip(self.profile), [])
        self.lock["resolved"]["extensions"] = {"archive": {"file": "archive.tar.gz"}}
        self.refresh_profile()
        self.assertEqual(w.extension_archive_skip(self.profile), ["/root/vscode-extensions.tar.gz"])
        self.lock["config"]["user"] = {"name": "developer"}
        self.refresh_profile()
        self.assertEqual(w.extension_archive_skip(self.profile), ["/home/developer/vscode-extensions.tar.gz"])

    def install_fake_scanner(self):
        scripts = self.repo / "scripts"
        scripts.mkdir()
        for name in ("scan-images-trivy.sh", "summarize-trivy-vulnerabilities.py"):
            shutil.copy(REPO / "scripts" / name, scripts / name)
        binaries = self.repo / "bin"
        binaries.mkdir()
        docker = binaries / "docker"
        docker.write_text('''#!/usr/bin/env python3
import json,os,sys
identity=json.loads(os.environ['FAKE_IDENTITY'])
if '--format' in sys.argv: print(identity['Id'])
else: print(json.dumps([identity]))
''')
        trivy = binaries / "trivy"
        trivy.write_text('''#!/usr/bin/env python3
import json,os,sys
assert not any(key.startswith('TRIVY_') for key in os.environ), 'ambient Trivy variable leaked'
args=sys.argv[1:]
context={'Version':'test','VulnerabilityDB':{'Version':2,'UpdatedAt':'2026-01-01'},'JavaDB':{'Version':1,'UpdatedAt':'2026-01-01'}}
if args[0]=='version': print(json.dumps(context)); sys.exit()
assert args[args.index('--config')+1]=='/dev/null'
if '--download-db-only' in args or '--download-java-db-only' in args: sys.exit()
for option in ('--skip-db-update','--skip-java-db-update','--offline-scan','--ignore-unfixed=false'): assert option in args
assert args[args.index('--severity')+1]=='UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL'
assert args[args.index('--ignorefile')+1]=='/dev/null'
image=args[-1]
identity=json.loads(os.environ['FAKE_IDENTITY'])
if args[args.index('--format')+1]=='json':
 findings=[]
 if os.environ.get('FAKE_HIGH')=='1': findings=[{'VulnerabilityID':'CVE-TEST','Severity':'HIGH','PkgName':'test','InstalledVersion':'1'}]
 value={'ArtifactName':image,'Metadata':{'ImageID':identity['Id']},'Results':[{'Target':'test','Vulnerabilities':findings}]}
else:
 value={'bomFormat':'CycloneDX','components':[],'metadata':{'component':{'name':image,'properties':[{'name':'aquasecurity:trivy:ImageID','value':identity['Id']}]}}}
with open(args[args.index('--output')+1],'w') as output: json.dump(value,output)
''')
        docker.chmod(0o755)
        trivy.chmod(0o755)
        return {"PATH": str(binaries) + ":" + os.environ["PATH"],
                "FAKE_IDENTITY": json.dumps(self.identity), "TRIVY_SEVERITY": "LOW",
                "TRIVY_IGNORE_UNFIXED": "true", "TRIVY_CONFIG": "/dangerous-config"}

    def scan_output(self):
        return self.profile.platform_root / "reports/scan"

    def test_raw_scan_sanitizes_environment_records_size_and_passes(self):
        environment = self.install_fake_scanner()
        with patch.dict(os.environ, environment), patch.object(self.profile, "verify"):
            w.scan(self.profile, self.args)
        report = w.read_json(self.scan_output() / "report.json")
        self.assertIs(report["passed"], True)
        self.assertEqual(report["sizeBytes"], 1234)
        self.assertEqual(report["imageId"], self.image_id)
        self.assertEqual(report["lockSha256"], self.profile.digest)
        self.assertTrue((self.scan_output() / "vulnerabilities.csv").exists())
        w.verify_scan(self.profile, self.scan_output())

    def test_high_finding_fails_and_skipped_gate_never_passes(self):
        environment = {**self.install_fake_scanner(), "FAKE_HIGH": "1"}
        with patch.dict(os.environ, environment), patch.object(self.profile, "verify"):
            with self.assertRaisesRegex(w.WorkflowError, "1 High"):
                w.scan(self.profile, self.args)
            self.assertIs(w.read_json(self.scan_output() / "acceptance.json")["passed"], False)
            self.args.skip_acceptance_gate = True
            w.scan(self.profile, self.args)
        acceptance = w.read_json(self.scan_output() / "acceptance.json")
        self.assertIs(acceptance["passed"], None)
        self.assertIs(acceptance["evaluated"], False)
        self.assertNotIn("**PASS**", (self.scan_output() / "report.md").read_text())

    def test_missing_or_stale_image_label_removes_previous_pass_first(self):
        self.scan_output().mkdir(parents=True)
        (self.scan_output() / "report.md").write_text("**PASS**")
        (self.scan_output() / "acceptance.json").write_text('{"passed":true}')
        with patch.object(self.profile, "verify"), patch.object(self.profile, "inspect", side_effect=w.WorkflowError("stale lock")):
            with self.assertRaisesRegex(w.WorkflowError, "stale"):
                w.scan(self.profile, self.args)
        self.assertFalse((self.scan_output() / "report.md").exists())
        self.assertFalse((self.scan_output() / "acceptance.json").exists())

    def test_invalid_lock_constructor_invalidates_old_and_current_report_locations(self):
        previous = self.scan_output()
        current = self.repo / "artifacts/wolfi/updated/linux-arm64/reports/scan"
        for directory in (previous, current):
            directory.mkdir(parents=True)
            (directory / "report.md").write_text("**PASS**")
        self.lock["schemaVersion"] = 1
        self.lock_path.write_text(json.dumps(self.lock))
        selected = argparse.Namespace(root=current.parents[2], platform="linux/arm64")
        self.args.config, self.args.lock = self.config, self.lock_path
        with patch.object(w, "CleanSelection", return_value=selected):
            w.invalidate_unavailable_scan(self.args, self.repo)
        self.assertFalse((previous / "report.md").exists())
        self.assertFalse((current / "report.md").exists())

    def test_missing_lock_invalidates_yaml_selected_report(self):
        output = self.scan_output()
        output.mkdir(parents=True)
        (output / "acceptance.json").write_text('{"passed":true}')
        self.lock_path.unlink()
        selected = argparse.Namespace(root=self.root, platform="linux/amd64")
        self.args.config, self.args.lock = self.config, self.lock_path
        with patch.object(w, "CleanSelection", return_value=selected):
            w.invalidate_unavailable_scan(self.args, self.repo)
        self.assertFalse((output / "acceptance.json").exists())

    def test_main_invalidates_constructor_failure_without_running_scan(self):
        argv = ["workflow.py", "scan", "--config", str(self.config), "--lock", str(self.lock_path)]
        with patch.object(w.sys, "argv", argv), patch.object(w, "Profile", side_effect=w.WorkflowError("invalid lock")), patch.object(w, "invalidate_unavailable_scan") as invalidate, patch.object(w, "scan") as scan:
            with self.assertRaisesRegex(SystemExit, "invalid lock"):
                w.main()
        invalidate.assert_called_once()
        scan.assert_not_called()

    def test_changed_raw_report_and_sbom_are_rejected(self):
        environment = self.install_fake_scanner()
        with patch.dict(os.environ, environment), patch.object(self.profile, "verify"):
            w.scan(self.profile, self.args)
        metadata = w.read_json(self.scan_output() / "scan-metadata.json")
        for field in ("vulnerabilities", "sbom"):
            path = self.scan_output() / metadata["reports"][0][field]
            original = path.read_bytes()
            path.write_bytes(original + b" ")
            with self.subTest(field=field), self.assertRaisesRegex(w.WorkflowError, "bytes changed"):
                w.verify_scan(self.profile, self.scan_output())
            path.write_bytes(original)


class OfflineLockTests(unittest.TestCase):
    """Exercise the real shell verifier without the optional Node dependencies."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name)
        self.config = self.repo / "profile.yaml"
        self.lock_path = self.repo / "profile.lock.json"
        self.config.write_bytes((REPO / "config/wolfi-dev.yaml").read_bytes())
        self.lock = w.read_json(REPO / "config/wolfi-dev.lock.json")

    def verify(self, lock):
        self.lock_path.write_text(json.dumps(lock))
        return w.run("bash", "-c", 'source "$1"; wolfi_verify_lock "$2" "$3" "$4"',
                     "_", str(REPO / "scripts/wolfi/lib.sh"), str(self.repo),
                     str(self.config), str(self.lock_path), capture=True, check=False)

    def reject(self, lock):
        result = self.verify(lock)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid frozen/offline shape", result.stderr)

    def test_offline_verifier_accepts_both_complete_sample_locks(self):
        for profile in ("ci", "dev"):
            with self.subTest(profile=profile):
                self.config.write_bytes((REPO / f"config/wolfi-{profile}.yaml").read_bytes())
                result = self.verify(w.read_json(REPO / f"config/wolfi-{profile}.lock.json"))
                self.assertEqual(result.returncode, 0, result.stderr)
        # VS Code can be selected without an archive, and tool downloads can be
        # omitted independently. The offline verifier must accept both choices.
        lock = copy.deepcopy(self.lock)
        lock["config"]["vscode"]["extensions"] = []
        del lock["resolved"]["extensions"]
        for key in ("kubectl", "rust"):
            del lock["config"]["build" if key == "rust" else "utilities"][key]
            del lock["resolved"][key]
        self.config.write_text(json.dumps(lock["config"]))
        lock["source"]["fileSha256"] = w.sha256(self.config)
        result = self.verify(lock)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_offline_verifier_rejects_missing_or_empty_selected_vendor_records(self):
        for key in ("vscode", "extensions", "kubectl", "rust"):
            for value in (None, {}, [], "absent"):
                with self.subTest(key=key, value=value):
                    lock = copy.deepcopy(self.lock)
                    if value == "absent":
                        del lock["resolved"][key]
                    else:
                        lock["resolved"][key] = value
                    self.reject(lock)

    def test_offline_verifier_rejects_vendor_records_for_disabled_selections(self):
        for key in ("vscode", "extensions", "kubectl", "rust"):
            for value in (self.lock["resolved"][key], None):
                with self.subTest(key=key, null=value is None):
                    lock = copy.deepcopy(self.lock)
                    if key == "vscode":
                        del lock["config"]["vscode"]
                        del lock["resolved"]["extensions"]
                    elif key == "extensions":
                        lock["config"]["vscode"]["extensions"] = []
                    else:
                        del lock["config"]["build" if key == "rust" else "utilities"][key]
                    lock["resolved"][key] = value
                    self.reject(lock)

    def test_offline_verifier_requires_one_complete_final_apk_set(self):
        final = self.lock["resolved"]["apk"]["packageSets"]["final"]
        for sets in (None, {}, {"final": None}, {"final": {}}, {"final": final, "probe": final}):
            with self.subTest(sets=list(sets) if isinstance(sets, dict) else sets):
                lock = copy.deepcopy(self.lock)
                lock["resolved"]["apk"]["packageSets"] = sets
                self.reject(lock)
        for key in ("artifactDirectory", "closure", "roots", "modules", "packages", "repositorySubdirs"):
            for value in (None, [], ""):
                with self.subTest(key=key, value=value):
                    lock = copy.deepcopy(self.lock)
                    lock["resolved"]["apk"]["packageSets"]["final"][key] = value
                    self.reject(lock)


if __name__ == "__main__":
    unittest.main()
