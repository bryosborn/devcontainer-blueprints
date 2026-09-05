#!/usr/bin/env python3
"""Behavioral checks for controlled A/B evidence and advisory counting."""

import copy
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts/wolfi"))
SPEC = importlib.util.spec_from_file_location("report_ab", REPO / "scripts/wolfi/report-ab.py")
a = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(a)


class ReportTests(unittest.TestCase):
    def test_repeated_advisory_counts_once_at_highest_severity(self):
        raw = {"Results": [{"Class": "os-pkgs", "Type": "wolfi", "Target": "image:tag (wolfi)",
                "Packages": [{"Name": "a", "Version": "1"}, {"Name": "b", "Version": "2"}],
                "Vulnerabilities": [{"VulnerabilityID": "CVE-2026-1", "Severity": "HIGH", "PkgName": "a"},
                                    {"VulnerabilityID": "CVE-2026-1", "Severity": "MEDIUM", "PkgName": "b"},
                                    {"VulnerabilityID": "GO-2026-2", "Severity": "UNKNOWN", "PkgName": "b"}]}]}
        findings, packages, apks = a.scan_inventory(raw)
        self.assertEqual(len(findings), 3)
        self.assertEqual(a.highest_severities(findings), {"CVE-2026-1": "HIGH", "GO-2026-2": "UNKNOWN"})
        self.assertEqual(findings[0]["target"], "/")
        self.assertEqual(apks, {"a": "1", "b": "2"})
        self.assertEqual(len(packages), 2)

    def test_language_graph_roots_and_unknown_versions_are_not_invented(self):
        raw = {"Results": [{"Type": "gobinary", "Packages": [{"Name": "k8s.io/kubectl"}]},
                           {"Type": "cargo", "Packages": [{"ID": "anonymous-root", "Relationship": "root"}]}]}
        _, packages, apks = a.scan_inventory(raw)
        self.assertEqual(packages, {("gobinary", "k8s.io/kubectl", "")})
        self.assertEqual(apks, {})

    def config(self):
        return {"image": {"reference": "example/default:1", "platform": "linux/amd64"},
                "artifacts": {"root": "artifacts/default"}, "build": {"node": "24", "npm": "12"},
                "utilities": {"curl": "latest"}}

    def variant(self, config, variant="playwright-on"):
        return {"profile": "ci", "variant": variant,
                "profileObject": SimpleNamespace(lock={"config": config})}

    def test_single_factor_accepts_coordinates_but_rejects_changed_compiler(self):
        baseline = self.config()
        selected = copy.deepcopy(baseline)
        selected["image"]["reference"] = "example/playwright:1"
        selected["artifacts"]["root"] = "artifacts/playwright"
        selected["playwright"] = {"version": "1.63.0"}
        a.verify_factor(baseline, self.variant(selected), {})
        selected["build"]["node"] = "26"
        with self.assertRaisesRegex(a.w.WorkflowError, "outside its single factor"):
            a.verify_factor(baseline, self.variant(selected), {})

    def test_all_utilities_excludes_separate_clamav_factor(self):
        baseline = self.config()
        selected = copy.deepcopy(baseline)
        selected["utilities"]["wget"] = "latest"
        catalog = {"curl": {}, "wget": {}, "clamav": {}}
        a.verify_factor(baseline, self.variant(selected, "utilities-all"), catalog)
        selected["utilities"]["clamav"] = "1.5"
        with self.assertRaisesRegex(a.w.WorkflowError, "except ClamAV"):
            a.verify_factor(baseline, self.variant(selected, "utilities-all"), catalog)

    def test_resolution_drift_is_explicit_and_payload_paths_are_irrelevant(self):
        resolved = {"apk": {"baseImage": {"digest": "base-a"}, "repositories": {"main": {"indexSha256": "index-a", "signatureKeyFingerprintsSha256": ["key-a"]}},
                            "packages": [{"name": "curl", "version": "1", "sha256": "bytes-a"}]},
                    "kubectl": {"file": "root-a/bin", "version": "1.37.0", "sha256": "kubectl-a"}}
        baseline = {"profileObject": SimpleNamespace(lock={"resolved": resolved})}
        selected = copy.deepcopy(baseline)
        selected["profileObject"].lock["resolved"]["kubectl"]["file"] = "root-b/bin"
        self.assertEqual(a.resolution_drift(baseline, selected), [])
        changed = selected["profileObject"].lock["resolved"]
        changed["apk"]["packages"][0]["sha256"] = "bytes-b"
        changed["apk"]["repositories"]["main"]["indexSha256"] = "index-b"
        changed["kubectl"]["sha256"] = "kubectl-b"
        notes = a.resolution_drift(baseline, selected)
        self.assertEqual(len(notes), 2)
        self.assertTrue(any("Shared APK changed" in note for note in notes))
        self.assertEqual(a.snapshot_differences(baseline, selected), ["main signed index indexSha256 changed"])

    def test_removed_occurrence_does_not_remove_an_id_still_present(self):
        finding = {"vulnerabilityId": "CVE-2026-1", "severity": "HIGH", "ecosystem": "wolfi",
                   "target": "/", "package": "a", "installedVersion": "1", "fixedVersion": "2"}
        resolved = {"apk": {"baseImage": {"digest": "base"}, "repositories": {}, "packages": []}}
        baseline = {"profile": "ci", "variant": "default", "sizeBytes": 100,
                    "ids": {"CVE-2026-1": "HIGH"}, "findings": [finding, {**finding, "package": "b"}],
                    "packages": {("wolfi", "a", "1"), ("wolfi", "b", "1")}, "apks": {"a": "1", "b": "1"},
                    "occurrences": {s: 2 if s == "HIGH" else 0 for s in a.SEVERITIES},
                    "unique": {s: 1 if s == "HIGH" else 0 for s in a.SEVERITIES},
                    "profileObject": SimpleNamespace(lock={"resolved": resolved})}
        selected = copy.deepcopy(baseline)
        selected.update({"variant": "utilities-none", "sizeBytes": 80, "findings": [finding],
                         "packages": {("wolfi", "a", "1")}, "apks": {"a": "1"}})
        selected["occurrences"]["HIGH"] = 1
        result = a.compare(baseline, selected)
        self.assertEqual(result["removedIds"], [])
        self.assertEqual(result["sizeDeltaBytes"], -20)
        self.assertEqual(len(result["removedOccurrences"]), 1)
        self.assertEqual(result["removedApks"], [("b", "1")])

    def test_extension_metadata_changes_are_distinct_from_vsix_payload_changes(self):
        before = {"archive": {"sha256": "archive-a", "size": 100}, "targetVscodeCommit": "commit-a",
                  "containerInstallOrder": ["example.extension"], "hostOnlyExtensions": [],
                  "packages": [{"id": "example.extension", "version": "1", "targetPlatform": "linux-x64",
                                "classification": "container", "sha256": "payload-a", "size": 80}],
                  "payloadLock": {"generatedAt": "yesterday", "cachePath": "root-a"}}
        after = copy.deepcopy(before)
        after["archive"] = {"sha256": "archive-b", "size": 101}
        after["payloadLock"] = {"generatedAt": "today", "cachePath": "root-b"}
        self.assertEqual(a.vendor_identity("extensions", before), a.vendor_identity("extensions", after))
        after["packages"][0]["sha256"] = "payload-b"
        self.assertNotEqual(a.vendor_identity("extensions", before), a.vendor_identity("extensions", after))

    def test_database_byte_tampering_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "db/trivy.db"
            path.parent.mkdir()
            path.write_bytes(b"database")
            records = [{"file": "db/trivy.db", "sha256": a.w.sha256(path)}]
            self.assertEqual(a.database_files(records, root), {"db/trivy.db": records[0]["sha256"]})
            path.write_bytes(b"changed database")
            with self.assertRaisesRegex(a.w.WorkflowError, "database bytes differ"):
                a.database_files(records, root)

    def test_changed_shipped_profile_is_rejected_before_comparison(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ci = root / "ci.yaml"
            dev = root / "dev.yaml"
            ci.write_text("schemaVersion: 2\n")
            dev.write_text("schemaVersion: 2\n")
            manifest = {"sourceProfiles": [
                {"profile": "ci", "file": "ci.yaml", "sha256": "0" * 64},
                {"profile": "dev", "file": "dev.yaml", "sha256": a.w.sha256(dev)},
            ]}
            with self.assertRaisesRegex(a.w.WorkflowError, "source configuration changed"):
                a.verify_source_profiles(manifest, [], root)

    def test_raw_report_tampering_uses_shared_scan_verifier(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "reports"
            output.mkdir()
            profile = SimpleNamespace(image="example/ci:1", platform="linux/amd64", digest="lock-hash",
                                      lock={"resolved": {}}, verify=lambda **_: None,
                                      inspect=lambda: {"Id": "image-id", "Size": 100})
            options = {"configFile": "/dev/null", "ambientTrivyEnvironmentCleared": True,
                       "imageSource": "docker", "scanners": ["vuln"], "severities": a.w.SEVERITIES,
                       "ignoreUnfixed": False, "ignoreFile": "/dev/null", "platform": "linux/amd64",
                       "offlineScan": True, "skipDbUpdate": True, "skipJavaDbUpdate": True,
                       "skipDirs": [], "skipFiles": [], "ignorePolicy": {"applied": False}}
            raw = output / "raw.json"
            sbom = output / "sbom.json"
            raw.write_text("{}")
            sbom.write_text("{}")
            metadata = {"lockSha256": profile.digest, "images": [profile.image], "scannerOptions": options,
                        "databaseIdentity": {name: {"updatedAt": "2026-09-05"} for name in ("vulnerability", "java")},
                        "imageIdentities": [{"reference": profile.image, "platform": profile.platform, "imageId": "image-id"}],
                        "reports": [{"image": profile.image, "vulnerabilities": "raw.json", "sbom": "sbom.json",
                                     "vulnerabilitiesSha256": a.w.sha256(raw), "sbomSha256": a.w.sha256(sbom)}]}
            (output / "scan-metadata.json").write_text(json.dumps(metadata))
            raw.write_text('{"tampered": true}')
            entry = {"profile": "ci", "variant": "default", "config": "config.yaml", "lock": "config.lock.json", "reports": "reports"}
            with patch.object(a.w, "Profile", return_value=profile), self.assertRaisesRegex(a.w.WorkflowError, "bytes changed"):
                a.read_variant(entry, {}, root)


if __name__ == "__main__":
    unittest.main()
