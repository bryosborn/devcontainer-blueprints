#!/usr/bin/env python3
"""Regression tests for frozen Trivy scans and Wolfi comparison reports."""

from __future__ import annotations

import csv
import hashlib
import importlib.util
import json
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCAN_SCRIPT = REPO_ROOT / "scripts" / "scan-images-trivy.sh"
WOLFI_SCAN_SCRIPT = REPO_ROOT / "scripts" / "wolfi" / "scan.sh"
COMPARE_SCRIPT = REPO_ROOT / "scripts" / "wolfi" / "compare.sh"
GATE_SCRIPT = REPO_ROOT / "scripts" / "wolfi" / "check-acceptance.py"
UBUNTU_PROFILE_SCRIPT = REPO_ROOT / "scripts" / "wolfi" / "build-ubuntu-all-tools.sh"
WOLFI_LOCK = REPO_ROOT / "config" / "wolfi-build.lock.json"
WOLFI_LOCK_SHA256 = hashlib.sha256(WOLFI_LOCK.read_bytes()).hexdigest()
COMPARE_MODULE_SPEC = importlib.util.spec_from_file_location(
    "wolfi_compare_reports", REPO_ROOT / "scripts" / "wolfi" / "compare-reports.py"
)
assert COMPARE_MODULE_SPEC is not None and COMPARE_MODULE_SPEC.loader is not None
COMPARE_MODULE = importlib.util.module_from_spec(COMPARE_MODULE_SPEC)
COMPARE_MODULE_SPEC.loader.exec_module(COMPARE_MODULE)
CSV_HEADERS = [
    "Container Name",
    "CVE",
    "Fix Available--Severity",
    "DAYS",
    "Status",
    "Remediation",
    "Target",
    "Package Class",
    "Package Type",
    "Package Name",
    "Package Path",
    "Installed Version",
    "Fixed Version",
    "CVSS Score",
    "Published Date",
    "Title",
    "Primary URL",
    "PURL",
    "Layer Digest",
]
TRIVY_CONTEXT = {
    "Version": "0.74.0",
    "VulnerabilityDB": {
        "Version": 2,
        "UpdatedAt": "2026-09-04T01:11:59Z",
        "DownloadedAt": "2026-09-04T02:00:00Z",
    },
    "JavaDB": {
        "Version": 1,
        "UpdatedAt": "2026-09-04T01:11:37Z",
        "DownloadedAt": "2026-09-04T02:00:00Z",
    },
}
TEST_IMAGE_ID = "sha256:" + "a" * 64


def write_executable(path: Path, content: str) -> None:
    path.write_text(textwrap.dedent(content).lstrip(), encoding="utf-8")
    path.chmod(0o755)


def install_fake_scan_commands(temporary: Path) -> tuple[dict[str, str], Path]:
    fake_bin = temporary / "bin"
    fake_bin.mkdir()
    trivy_log = temporary / "trivy.log"
    write_executable(
        fake_bin / "docker",
        """
        #!/usr/bin/env bash
        set -euo pipefail
        if [[ "$1 $2" == "image inspect" ]]; then
          if [[ -n "${FAKE_DOCKER_MISSING_IMAGE:-}" \
            && " $* " == *" ${FAKE_DOCKER_MISSING_IMAGE} "* ]]; then
            exit 1
          fi
          if [[ " $* " == *" --format "* ]]; then
            case "$*" in
              *'{{.Id}}'*) printf '%s\n' "sha256:$(printf 'a%.0s' {1..64})" ;;
              *'devcontainers.wolfi.lock.sha256'*) printf '%s\n' "${FAKE_WOLFI_LOCK_SHA256}" ;;
              *) printf 'linux/amd64\n' ;;
            esac
          else
            printf '[{"Id":"sha256:%s","Os":"linux","Architecture":"amd64","Created":"2026-09-04T00:00:00Z","Size":42,"RepoDigests":[]}]\n' \
              "$(printf 'a%.0s' {1..64})"
          fi
          exit 0
        fi
        if [[ "$1 $2" == "container run" ]]; then exit 0; fi
        echo "unexpected fake docker invocation: $*" >&2
        exit 1
        """,
    )
    write_executable(
        fake_bin / "trivy",
        """
        #!/usr/bin/env bash
        set -euo pipefail
        if [[ "$1" == "version" ]]; then
          printf '%s\n' "${FAKE_TRIVY_VERSION_JSON}"
          exit 0
        fi
        original_args="$*"
        if [[ " $* " == *" --download-db-only "* ]] \
          || [[ " $* " == *" --download-java-db-only "* ]]; then
          exit 0
        fi
        printf '%s\n' "$*" >> "${FAKE_TRIVY_LOG}"
        output=""
        format=""
        image="${!#}"
        while (($# > 0)); do
          case "$1" in
            --output) output="$2"; shift 2 ;;
            --format) format="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        if [[ "${format}" == "json" ]]; then
          raw_hardening=true
          if env | cut -d= -f1 | grep -q '^TRIVY_'; then raw_hardening=false; fi
          [[ " ${original_args} " == *" --config /dev/null "* ]] || raw_hardening=false
          [[ " ${original_args} " == *" --ignorefile /dev/null "* ]] || raw_hardening=false
          [[ " ${original_args} " == *" --severity UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL "* ]] \
            || raw_hardening=false
          [[ " ${original_args} " == *" --ignore-unfixed=false "* ]] || raw_hardening=false
          if [[ "${FAKE_TRIVY_REQUIRE_RAW_HARDENING:-false}" == true \
                && "${raw_hardening}" == true ]]; then
            printf '{"ArtifactName":"%s","Metadata":{"ImageID":"%s"},"Results":[{"Target":"fixture","Class":"os-pkgs","Type":"wolfi","Vulnerabilities":[{"VulnerabilityID":"CVE-RAW-HIGH","Severity":"HIGH","PkgName":"fixture","InstalledVersion":"1","FixedVersion":"2"}]}]}\n' \
              "${image}" "${FAKE_TRIVY_REPORT_IMAGE_ID}" > "${output}"
          else
            printf '{"ArtifactName":"%s","Metadata":{"ImageID":"%s"},"Results":[]}\n' \
              "${image}" "${FAKE_TRIVY_REPORT_IMAGE_ID}" > "${output}"
          fi
        else
          printf '{"bomFormat":"CycloneDX","metadata":{"component":{"name":"%s","properties":[{"name":"aquasecurity:trivy:ImageID","value":"%s"}]}},"components":[]}\n' \
            "${image}" "${FAKE_TRIVY_REPORT_IMAGE_ID}" > "${output}"
        fi
        """,
    )
    environment = os.environ.copy()
    environment["PATH"] = f"{fake_bin}:{environment['PATH']}"
    environment["FAKE_TRIVY_LOG"] = str(trivy_log)
    environment["FAKE_TRIVY_VERSION_JSON"] = json.dumps(TRIVY_CONTEXT)
    environment["FAKE_TRIVY_REPORT_IMAGE_ID"] = TEST_IMAGE_ID
    environment["FAKE_WOLFI_LOCK_SHA256"] = WOLFI_LOCK_SHA256
    return environment, trivy_log


def write_report(
    directory: Path,
    safe_name: str,
    image: str,
    vulnerabilities: list[dict[str, object]],
) -> tuple[str, str]:
    report = {
        "ArtifactName": image,
        "Metadata": {"ImageID": TEST_IMAGE_ID},
        "Results": [
            {
                "Target": "usr/bin/tools",
                "Class": "lang-pkgs",
                "Type": "gobinary",
                "Vulnerabilities": vulnerabilities,
            }
        ],
    }
    vulnerability_name = f"{safe_name}.vulnerabilities.json"
    sbom_name = f"{safe_name}.sbom.cdx.json"
    (directory / vulnerability_name).write_text(json.dumps(report), encoding="utf-8")
    (directory / sbom_name).write_text(
        json.dumps(
            {
                "bomFormat": "CycloneDX",
                "components": [
                    {"name": "parent", "components": [{"name": "child"}]},
                ],
            }
        ),
        encoding="utf-8",
    )
    return vulnerability_name, sbom_name


def write_scan_metadata(
    directory: Path,
    label: str,
    reports: list[tuple[str, str, str]],
    *,
    policy: bool = False,
    database_updated_at: str = "2026-09-04T01:11:59Z",
) -> None:
    trivy = json.loads(json.dumps(TRIVY_CONTEXT))
    trivy["VulnerabilityDB"]["UpdatedAt"] = database_updated_at
    payload = {
        "schemaVersion": 1,
        "label": label,
        "trivy": trivy,
        "databaseIdentity": {
            "vulnerability": {
                "version": 2,
                "updatedAt": database_updated_at,
            },
            "java": {"version": 1, "updatedAt": "2026-09-04T01:11:37Z"},
        },
        "scannerOptions": {
            "imageSource": "docker",
            "scanners": ["vuln"],
            "platform": "linux/amd64",
            "offlineScan": True,
            "skipDbUpdate": True,
            "skipJavaDbUpdate": True,
            "skipFiles": ["/home/vscode/vscode-extensions.tar.gz"],
            "skipDirs": [],
            "ignorePolicy": {
                "applied": policy,
                "path": "/policy.rego" if policy else "",
                "sha256": "a" * 64 if policy else "",
            },
        },
        "images": [image for image, _, _ in reports],
        "imageIdentities": [
            {
                "reference": image,
                "imageId": TEST_IMAGE_ID,
                "platform": "linux/amd64",
                "created": "2026-09-04T00:00:00Z",
                "sizeBytes": 42,
                "repoDigests": [],
            }
            for image, _, _ in reports
        ],
        "reports": [
            {
                "image": image,
                "vulnerabilities": vulnerability,
                "sbom": sbom,
                "vulnerabilitiesSha256": hashlib.sha256(
                    (directory / vulnerability).read_bytes()
                ).hexdigest(),
                "sbomSha256": hashlib.sha256((directory / sbom).read_bytes()).hexdigest(),
            }
            for image, vulnerability, sbom in reports
        ],
    }
    (directory / "scan-metadata.json").write_text(
        json.dumps(payload), encoding="utf-8"
    )


def write_native_version_report(path: Path) -> None:
    path.write_text(
        json.dumps(
            {
                "image": "devcontainers/wolfi-base-toolchain:0.1.0",
                "nativeTool": "mongosh",
                "enabled": True,
                "apkVersion": "2.10.0-r1",
                "runtimeVersion": "2.9.1",
                "packageRuntimeVersionDiscrepancy": True,
            }
        ),
        encoding="utf-8",
    )


class ScannerTests(unittest.TestCase):
    def test_explicit_raw_scan_preserves_formats_and_records_context(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            environment, trivy_log = install_fake_scan_commands(temporary)
            output_dir = temporary / "raw-output"
            subprocess.run(
                [
                    str(SCAN_SCRIPT),
                    "--image",
                    "devcontainers/wolfi-base-dod:0.1.0",
                    "--output-dir",
                    str(output_dir),
                    "--no-ignore-policy",
                    "--platform",
                    "linux/amd64",
                    "--cache-dir",
                    str(temporary / "cache"),
                    "--skip-db-update",
                    "--skip-java-db-update",
                    "--offline-scan",
                    "--skip-file",
                    "/home/vscode/vscode-extensions.tar.gz",
                ],
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )

            prefix = "devcontainers_wolfi-base-dod_0.1.0"
            self.assertTrue((output_dir / f"{prefix}.vulnerabilities.json").is_file())
            self.assertTrue((output_dir / f"{prefix}.sbom.cdx.json").is_file())
            self.assertEqual(
                (output_dir / "vulnerability-summary.tsv").read_text(encoding="utf-8"),
                "IMAGE\tUNKNOWN\tLOW\tMEDIUM\tHIGH\tCRITICAL\tTOTAL\n"
                "devcontainers/wolfi-base-dod:0.1.0\t0\t0\t0\t0\t0\t0\n",
            )
            with (output_dir / "vulnerabilities.csv").open(
                encoding="utf-8", newline=""
            ) as csv_file:
                self.assertEqual(next(csv.reader(csv_file)), CSV_HEADERS)

            metadata = json.loads(
                (output_dir / "scan-metadata.json").read_text(encoding="utf-8")
            )
            self.assertEqual(metadata["trivy"]["Version"], "0.74.0")
            self.assertEqual(
                metadata["databaseIdentity"]["vulnerability"]["updatedAt"],
                "2026-09-04T01:11:59Z",
            )
            self.assertTrue(metadata["scannerOptions"]["offlineScan"])
            self.assertFalse(metadata["scannerOptions"]["ignorePolicy"]["applied"])
            self.assertEqual(metadata["imageIdentities"][0]["imageId"], TEST_IMAGE_ID)
            self.assertRegex(
                metadata["reports"][0]["vulnerabilitiesSha256"], r"^[a-f0-9]{64}$"
            )
            self.assertRegex(metadata["reports"][0]["sbomSha256"], r"^[a-f0-9]{64}$")
            invocation = trivy_log.read_text(encoding="utf-8")
            self.assertIn("--skip-db-update", invocation)
            self.assertIn("--skip-java-db-update", invocation)
            self.assertIn("--offline-scan", invocation)
            self.assertIn("--skip-files /home/vscode/vscode-extensions.tar.gz", invocation)

    def test_report_filename_collision_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            environment, _ = install_fake_scan_commands(temporary)
            result = subprocess.run(
                [
                    str(SCAN_SCRIPT),
                    "--image",
                    "example/foo:1",
                    "--image",
                    "example_foo:1",
                    "--output-dir",
                    str(temporary / "output"),
                    "--no-ignore-policy",
                ],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("same report filename", result.stderr)

    def test_trivy_report_image_identity_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            environment, _ = install_fake_scan_commands(temporary)
            environment["FAKE_TRIVY_REPORT_IMAGE_ID"] = "sha256:" + "b" * 64
            output_dir = temporary / "output"
            output_dir.mkdir()
            stale_metadata = output_dir / "scan-metadata.json"
            stale_metadata.write_text('{"stale":true}\n', encoding="utf-8")
            result = subprocess.run(
                [
                    str(SCAN_SCRIPT),
                    "--image",
                    "example/image:1",
                    "--output-dir",
                    str(output_dir),
                    "--no-ignore-policy",
                ],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("identity does not match", result.stderr)
            self.assertFalse(stale_metadata.exists())

    def test_raw_scan_ignores_ambient_trivy_filters_and_config_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            environment, trivy_log = install_fake_scan_commands(temporary)
            environment.update(
                {
                    "FAKE_TRIVY_REQUIRE_RAW_HARDENING": "true",
                    "TRIVY_SEVERITY": "LOW",
                    "TRIVY_IGNORE_UNFIXED": "true",
                    "TRIVY_IGNORE_STATUS": "fixed",
                    "TRIVY_VEX": str(temporary / "hostile.vex.json"),
                }
            )
            (temporary / "trivy.yaml").write_text(
                "severity: [LOW]\nignore-unfixed: true\n", encoding="utf-8"
            )
            (temporary / ".trivyignore").write_text(
                "CVE-RAW-HIGH\n", encoding="utf-8"
            )
            output_dir = temporary / "output"
            subprocess.run(
                [
                    str(SCAN_SCRIPT),
                    "--image",
                    "example/image:1",
                    "--output-dir",
                    str(output_dir),
                    "--no-ignore-policy",
                ],
                check=True,
                capture_output=True,
                text=True,
                env=environment,
                cwd=temporary,
            )

            report = json.loads(
                (output_dir / "example_image_1.vulnerabilities.json").read_text(
                    encoding="utf-8"
                )
            )
            vulnerabilities = report["Results"][0]["Vulnerabilities"]
            self.assertEqual(
                [item["VulnerabilityID"] for item in vulnerabilities],
                ["CVE-RAW-HIGH"],
            )
            metadata = json.loads(
                (output_dir / "scan-metadata.json").read_text(encoding="utf-8")
            )
            options = metadata["scannerOptions"]
            self.assertEqual(options["configFile"], "/dev/null")
            self.assertTrue(options["ambientTrivyEnvironmentCleared"])
            self.assertEqual(options["ignoreFile"], "/dev/null")
            self.assertFalse(options["ignoreUnfixed"])
            self.assertEqual(
                options["severities"],
                ["UNKNOWN", "LOW", "MEDIUM", "HIGH", "CRITICAL"],
            )
            invocations = trivy_log.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(invocations), 2)
            self.assertTrue(all("--config /dev/null" in line for line in invocations))
            self.assertTrue(all("--ignorefile /dev/null" in line for line in invocations))

    def test_fair_ubuntu_builder_rejects_registry_tag(self) -> None:
        result = subprocess.run(
            [
                str(UBUNTU_PROFILE_SCRIPT),
                "--image",
                "registry.example.invalid/team/profile:1",
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("local-only image tag", result.stderr)

    def test_locked_wolfi_acceptance_cannot_use_ignore_policy(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            environment, _ = install_fake_scan_commands(temporary)
            result = subprocess.run(
                [
                    str(WOLFI_SCAN_SCRIPT),
                    "--no-ubuntu",
                    "--ignore-policy",
                    str(REPO_ROOT / "config" / "trivy-ignore.rego"),
                    "--cache-dir",
                    str(temporary / "cache"),
                    "--skip-db-download",
                ],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must be scanned without an ignore policy", result.stderr)

    def test_image_lock_label_tracks_exact_lock_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            environment, _ = install_fake_scan_commands(temporary)
            lock_file = temporary / "lock.json"
            lock_file.write_text('{"generatedAt":"first"}', encoding="utf-8")
            environment["FAKE_WOLFI_LOCK_SHA256"] = hashlib.sha256(
                lock_file.read_bytes()
            ).hexdigest()
            command = [
                "bash",
                "-c",
                'source "$1"; wolfi_verify_image_lock fixture/image:1 "$2"',
                "bash",
                str(REPO_ROOT / "scripts" / "wolfi" / "lib.sh"),
                str(lock_file),
            ]
            subprocess.run(
                command,
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )

            # JSON semantics are unchanged, but the exact generated bytes are
            # now different; an image carrying the old label must be stale.
            lock_file.write_text('{"generatedAt":"first"}\n', encoding="utf-8")
            result = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("current exact lock bytes", result.stderr)

    def test_default_wolfi_scan_rejects_stale_lock_labeled_images(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            environment, trivy_log = install_fake_scan_commands(temporary)
            environment["FAKE_WOLFI_LOCK_SHA256"] = "b" * 64
            result = subprocess.run(
                [
                    str(WOLFI_SCAN_SCRIPT),
                    "--no-ubuntu",
                    "--output-dir",
                    str(temporary / "wolfi"),
                    "--cache-dir",
                    str(temporary / "cache"),
                    "--skip-db-download",
                    "--skip-acceptance-gate",
                ],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("current exact lock bytes", result.stderr)
            self.assertFalse(trivy_log.exists())

    def test_default_wolfi_scan_requires_every_configured_native_tool_probe(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            environment, trivy_log = install_fake_scan_commands(temporary)
            missing_probe = "devcontainers/wolfi-base-toolchain:0.1.0-probe-oras"
            environment["FAKE_DOCKER_MISSING_IMAGE"] = missing_probe
            result = subprocess.run(
                [
                    str(WOLFI_SCAN_SCRIPT),
                    "--no-ubuntu",
                    "--output-dir",
                    str(temporary / "wolfi"),
                    "--cache-dir",
                    str(temporary / "cache"),
                    "--skip-db-download",
                    "--skip-acceptance-gate",
                ],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("requires every configured native-tool probe", result.stderr)
            self.assertIn(missing_probe, result.stderr)
            self.assertFalse(trivy_log.exists())

    def test_custom_wolfi_scan_does_not_require_locked_probe_set(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            environment, trivy_log = install_fake_scan_commands(temporary)
            suite_file = temporary / "suite.json"
            subprocess.run(
                [
                    str(WOLFI_SCAN_SCRIPT),
                    "--image",
                    "example/custom-wolfi:diagnostic",
                    "--no-ubuntu",
                    "--output-dir",
                    str(temporary / "wolfi"),
                    "--suite-file",
                    str(suite_file),
                    "--cache-dir",
                    str(temporary / "cache"),
                    "--skip-db-download",
                    "--skip-acceptance-gate",
                ],
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )
            suite = json.loads(suite_file.read_text(encoding="utf-8"))
            assessment = suite["wolfi"]["nativeToolProbeAssessment"]
            self.assertFalse(assessment["lockedDefaultEvaluation"])
            self.assertFalse(assessment["complete"])
            self.assertEqual(assessment["requiredProbes"], [])
            self.assertEqual(suite["wolfi"]["probeImages"], [])
            self.assertTrue(trivy_log.is_file())

    def test_default_ubuntu_behavior_still_uses_default_ignore_policy(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            environment, trivy_log = install_fake_scan_commands(temporary)
            env_file = temporary / "docker.env"
            env_file.write_text(
                "DOCKER_PLATFORM=linux/amd64\n"
                'ARTIFACT_IMAGE_REFS="example/one:1 example/two:2"\n',
                encoding="utf-8",
            )
            environment["DOCKER_ENV_FILE"] = str(env_file)
            subprocess.run(
                [str(SCAN_SCRIPT), "--output-dir", str(temporary / "output")],
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )
            invocations = trivy_log.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(invocations), 4)
            expected_policy = str(REPO_ROOT / "config" / "trivy-ignore.rego")
            self.assertTrue(
                all(f"--ignore-policy {expected_policy}" in line for line in invocations)
            )

    def test_wolfi_suite_uses_one_frozen_raw_context_and_separate_policy(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            environment, trivy_log = install_fake_scan_commands(temporary)
            wolfi_dir = temporary / "wolfi"
            ubuntu_dir = temporary / "ubuntu-raw"
            policy_dir = temporary / "ubuntu-policy"
            suite_file = temporary / "suite.json"
            subprocess.run(
                [
                    str(WOLFI_SCAN_SCRIPT),
                    "--output-dir",
                    str(wolfi_dir),
                    "--ubuntu-output-dir",
                    str(ubuntu_dir),
                    "--ubuntu-policy-dir",
                    str(policy_dir),
                    "--cache-dir",
                    str(temporary / "cache"),
                    "--suite-file",
                    str(suite_file),
                    "--skip-db-download",
                    "--skip-acceptance-gate",
                ],
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )
            ubuntu_metadata = json.loads(
                (ubuntu_dir / "scan-metadata.json").read_text(encoding="utf-8")
            )
            wolfi_metadata = json.loads(
                (wolfi_dir / "scan-metadata.json").read_text(encoding="utf-8")
            )
            policy_metadata = json.loads(
                (policy_dir / "scan-metadata.json").read_text(encoding="utf-8")
            )
            self.assertEqual(
                ubuntu_metadata["databaseIdentity"], wolfi_metadata["databaseIdentity"]
            )
            self.assertFalse(
                ubuntu_metadata["scannerOptions"]["ignorePolicy"]["applied"]
            )
            self.assertFalse(
                wolfi_metadata["scannerOptions"]["ignorePolicy"]["applied"]
            )
            self.assertTrue(policy_metadata["scannerOptions"]["ignorePolicy"]["applied"])
            self.assertIn(
                "/home/vscode/vscode-extensions.tar.gz",
                wolfi_metadata["scannerOptions"]["skipFiles"],
            )
            suite = json.loads(suite_file.read_text(encoding="utf-8"))
            self.assertTrue(suite["scannerContextFrozen"])
            self.assertEqual(suite["wolfi"]["lockSha256"], WOLFI_LOCK_SHA256)
            probe_assessment = suite["wolfi"]["nativeToolProbeAssessment"]
            self.assertTrue(probe_assessment["lockedDefaultEvaluation"])
            self.assertTrue(probe_assessment["complete"])
            self.assertEqual(
                [probe["toolKey"] for probe in probe_assessment["requiredProbes"]],
                ["core", "helm", "oras", "mongosh", "mongodbDatabaseTools"],
            )
            self.assertEqual(
                [probe["image"] for probe in probe_assessment["requiredProbes"]],
                suite["wolfi"]["probeImages"],
            )
            # This fixture intentionally supplies no comparator provenance
            # labels. The default path must fall back to the normal Ubuntu
            # toolchain rather than calling that image equivalent.
            self.assertEqual(
                suite["ubuntu"]["allToolsComparison"]["status"], "unavailable"
            )
            self.assertFalse(
                suite["ubuntu"]["allToolsComparison"]["equivalent"]
            )
            self.assertEqual(
                suite["ubuntu"]["allToolsComparison"]["expectedVersions"]["helm"],
                "3.21.4",
            )
            acceptance = json.loads(
                (wolfi_dir / "acceptance.json").read_text(encoding="utf-8")
            )
            self.assertFalse(acceptance["evaluated"])
            self.assertIsNone(acceptance["passed"])
            invocations = trivy_log.read_text(encoding="utf-8").splitlines()
            self.assertTrue(all("--offline-scan" in line for line in invocations))

    def test_acceptance_gate_writes_details_and_fails_on_high(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            report_name, _ = write_report(
                temporary,
                "wolfi",
                "devcontainers/wolfi-base-dod:0.1.0",
                [
                    {
                        "VulnerabilityID": "CVE-HIGH",
                        "Severity": "HIGH",
                        "PkgName": "docker-cli",
                    }
                ],
            )
            output = temporary / "acceptance.json"
            result = subprocess.run(
                [
                    "python3",
                    str(GATE_SCRIPT),
                    "--output",
                    str(output),
                    str(temporary / report_name),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            payload = json.loads(output.read_text(encoding="utf-8"))
            self.assertTrue(payload["evaluated"])
            self.assertFalse(payload["passed"])
            self.assertEqual(payload["occurrences"]["HIGH"], 1)


class ComparisonTests(unittest.TestCase):
    def test_failed_staging_quarantines_previous_pass_without_mixed_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            output_dir = temporary / "comparison"
            output_dir.mkdir()
            previous_outputs = {
                "comparison.json": '{"generation":"previous"}\n',
                "comparison.md": "previous complete report\n",
            }
            for name, contents in previous_outputs.items():
                (output_dir / name).write_text(contents, encoding="utf-8")

            previous_dir = COMPARE_MODULE.quarantine_current_output_directory(
                output_dir
            )
            self.assertIsNotNone(previous_dir)
            assert previous_dir is not None
            self.assertFalse(output_dir.exists())

            def fail_after_partial_staging(staging_dir: Path) -> None:
                (staging_dir / "comparison.json").write_text(
                    '{"generation":"partial-new"}\n', encoding="utf-8"
                )
                raise RuntimeError("simulated report writer failure")

            with self.assertRaisesRegex(RuntimeError, "simulated report writer failure"):
                COMPARE_MODULE.publish_complete_output_directory(
                    output_dir, fail_after_partial_staging, previous_dir
                )

            self.assertFalse(output_dir.exists())
            self.assertEqual(
                {
                    path.name: path.read_text(encoding="utf-8")
                    for path in previous_dir.iterdir()
                },
                previous_outputs,
            )
            self.assertEqual(
                [
                    path.name
                    for path in temporary.iterdir()
                    if path.name.startswith(".comparison.staging-")
                ],
                [],
            )

    def test_validation_failure_leaves_no_stale_canonical_pass(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            ubuntu_dir, wolfi_dir, policy_dir, suite_file = self.make_comparison_fixture(
                temporary
            )
            wolfi_metadata_path = wolfi_dir / "scan-metadata.json"
            wolfi_metadata = json.loads(
                wolfi_metadata_path.read_text(encoding="utf-8")
            )
            wolfi_metadata["databaseIdentity"]["vulnerability"]["updatedAt"] = (
                "2026-09-05T01:11:59Z"
            )
            wolfi_metadata_path.write_text(
                json.dumps(wolfi_metadata), encoding="utf-8"
            )

            output_dir = temporary / "comparison"
            output_dir.mkdir()
            stale_pass = '{"releaseGate":{"status":"PASS"}}\n'
            (output_dir / "comparison.json").write_text(
                stale_pass, encoding="utf-8"
            )

            result = subprocess.run(
                [
                    str(COMPARE_SCRIPT),
                    "--ubuntu-dir",
                    str(ubuntu_dir),
                    "--wolfi-dir",
                    str(wolfi_dir),
                    "--ubuntu-policy-dir",
                    str(policy_dir),
                    "--suite-file",
                    str(suite_file),
                    "--output-dir",
                    str(output_dir),
                    "--skip-image-metrics",
                ],
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("database snapshot", result.stderr)
            self.assertFalse(output_dir.exists())
            previous_dirs = list(temporary.glob(".comparison.previous-*"))
            self.assertEqual(len(previous_dirs), 1)
            self.assertEqual(
                (previous_dirs[0] / "comparison.json").read_text(encoding="utf-8"),
                stale_pass,
            )
            self.assertEqual(list(temporary.glob(".comparison.staging-*")), [])

    def make_comparison_fixture(self, temporary: Path) -> tuple[Path, Path, Path, Path]:
        ubuntu_dir = temporary / "ubuntu"
        wolfi_dir = temporary / "wolfi"
        policy_dir = temporary / "policy"
        output_dir = temporary / "comparison"
        ubuntu_dir.mkdir()
        wolfi_dir.mkdir()
        policy_dir.mkdir()

        ubuntu_images = [
            "devcontainers/base-dod:0.2.0",
            "devcontainers/base-vscode:0.2.0",
            "devcontainers/base-toolchain:0.2.0-wolfi-comparison-all-tools",
        ]
        wolfi_images = [
            "devcontainers/wolfi-base-dod:0.1.0",
            "devcontainers/wolfi-base-vscode:0.1.0",
            "devcontainers/wolfi-base-toolchain:0.1.0",
            "devcontainers/wolfi-base-toolchain:0.1.0-core",
            "devcontainers/wolfi-base-toolchain:0.1.0-probe-helm",
            "devcontainers/wolfi-base-toolchain:0.1.0-probe-oras",
            "devcontainers/wolfi-base-toolchain:0.1.0-probe-mongosh",
            "devcontainers/wolfi-base-toolchain:0.1.0-probe-mongodb-database-tools",
        ]

        ubuntu_reports = []
        policy_reports = []
        for index, image in enumerate(ubuntu_images):
            vulnerabilities = []
            if index == 2:
                vulnerabilities = [
                    {
                        "VulnerabilityID": "CVE-1",
                        "Severity": "HIGH",
                        "PkgName": "helm",
                        "InstalledVersion": "3.0",
                        "FixedVersion": "3.1",
                    },
                    {
                        "VulnerabilityID": "CVE-1",
                        "Severity": "HIGH",
                        "PkgName": "helm-helper",
                        "InstalledVersion": "3.0",
                        "FixedVersion": "3.1",
                    },
                ]
            vulnerability, sbom = write_report(
                ubuntu_dir, f"ubuntu-{index}", image, vulnerabilities
            )
            ubuntu_reports.append((image, vulnerability, sbom))
            vulnerability, sbom = write_report(
                policy_dir, f"ubuntu-{index}", image, vulnerabilities
            )
            policy_reports.append((image, vulnerability, sbom))

        wolfi_reports = []
        for index, image in enumerate(wolfi_images):
            vulnerabilities = []
            if image.endswith(":0.1.0"):
                vulnerabilities = [
                    {
                        "VulnerabilityID": "CVE-2",
                        "Severity": "LOW",
                        "PkgName": "mongosh",
                        "InstalledVersion": "2.10.0",
                        "FixedVersion": "",
                        "Layer": {"Digest": "sha256:mongosh"},
                    },
                    {
                        "VulnerabilityID": "CVE-3",
                        "Severity": "MEDIUM",
                        "PkgName": "mongoexport",
                        "InstalledVersion": "100.0",
                        "FixedVersion": "100.1",
                        "Layer": {"Digest": "sha256:mongo-tools"},
                    },
                ]
            if image.endswith("probe-helm"):
                vulnerabilities = [
                    {
                        "VulnerabilityID": "CVE-4",
                        "Severity": "LOW",
                        "PkgName": "helm",
                        "InstalledVersion": "4.0",
                        "FixedVersion": "",
                    }
                ]
            vulnerability, sbom = write_report(
                wolfi_dir, f"wolfi-{index}", image, vulnerabilities
            )
            wolfi_reports.append((image, vulnerability, sbom))

        write_scan_metadata(ubuntu_dir, "ubuntu-raw", ubuntu_reports)
        write_scan_metadata(wolfi_dir, "wolfi-raw", wolfi_reports)
        write_scan_metadata(policy_dir, "ubuntu-policy", policy_reports, policy=True)

        suite_file = temporary / "suite.json"
        suite_file.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "scannerContextFrozen": True,
                    "includeVsixArchive": False,
                    "platform": "linux/amd64",
                    "trivy": TRIVY_CONTEXT,
                    "wolfi": {
                        "lockSha256": WOLFI_LOCK_SHA256,
                        "images": wolfi_images,
                        "finalImages": wolfi_images[:3],
                        "probeImages": wolfi_images[3:],
                        "nativeToolProbeAssessment": {
                            "lockedDefaultEvaluation": True,
                            "complete": True,
                            "requiredProbes": [
                                {"toolKey": "core", "image": wolfi_images[3]},
                                {"toolKey": "helm", "image": wolfi_images[4]},
                                {"toolKey": "oras", "image": wolfi_images[5]},
                                {"toolKey": "mongosh", "image": wolfi_images[6]},
                                {
                                    "toolKey": "mongodbDatabaseTools",
                                    "image": wolfi_images[7],
                                },
                            ],
                        },
                        "ignorePolicyApplied": False,
                        "boundaries": {
                            "dod": wolfi_images[0],
                            "vscode": wolfi_images[1],
                            "toolchain": wolfi_images[2],
                        },
                    },
                    "ubuntu": {
                        "enabled": True,
                        "images": ubuntu_images,
                        "boundaries": {
                            "dod": ubuntu_images[0],
                            "vscode": ubuntu_images[1],
                            "normalToolchain": "devcontainers/base-toolchain:0.2.0",
                        },
                        "allToolsComparison": {
                            "image": ubuntu_images[2],
                            "status": "included",
                            "equivalent": True,
                            "reason": "fixture all-tools profile",
                            "provenance": {
                                "validated": True,
                                "scanIdentityValidated": True,
                            },
                        },
                    },
                }
            ),
            encoding="utf-8",
        )
        subprocess.run(
            [
                "python3",
                str(GATE_SCRIPT),
                "--output",
                str(wolfi_dir / "acceptance.json"),
                *[
                    str(wolfi_dir / vulnerability)
                    for _, vulnerability, _ in wolfi_reports[:3]
                ],
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        return ubuntu_dir, wolfi_dir, policy_dir, suite_file

    def test_verified_counts_tools_boundaries_and_diagnostic_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            ubuntu_dir, wolfi_dir, policy_dir, suite_file = self.make_comparison_fixture(
                temporary
            )
            output_dir = temporary / "comparison"
            output_dir.mkdir()
            (output_dir / "stale-from-previous-run.tsv").write_text(
                "stale\n", encoding="utf-8"
            )
            native_versions = temporary / "native-tool-versions.json"
            native_versions.write_text(
                json.dumps(
                    {
                        "image": "devcontainers/wolfi-base-toolchain:0.1.0",
                        "nativeTool": "mongosh",
                        "enabled": True,
                        "apkVersion": "2.10.0-r1",
                        "runtimeVersion": "2.9.1",
                        "packageRuntimeVersionDiscrepancy": True,
                    }
                ),
                encoding="utf-8",
            )
            subprocess.run(
                [
                    str(COMPARE_SCRIPT),
                    "--ubuntu-dir",
                    str(ubuntu_dir),
                    "--wolfi-dir",
                    str(wolfi_dir),
                    "--ubuntu-policy-dir",
                    str(policy_dir),
                    "--suite-file",
                    str(suite_file),
                    "--acceptance-file",
                    str(wolfi_dir / "acceptance.json"),
                    "--native-tool-version-report",
                    str(native_versions),
                    "--output-dir",
                    str(output_dir),
                    "--skip-image-metrics",
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            comparison = json.loads(
                (output_dir / "comparison.json").read_text(encoding="utf-8")
            )
            self.assertTrue(comparison["scanContext"]["verified"])
            self.assertEqual(comparison["releaseGate"]["status"], "PASS")
            self.assertTrue(comparison["releaseGate"]["evaluated"])
            self.assertTrue(comparison["releaseGate"]["verified"])
            self.assertTrue(comparison["releaseGate"]["passed"])
            self.assertTrue(
                comparison["nativeToolVersions"]["packageRuntimeVersionDiscrepancy"]
            )
            ubuntu = comparison["families"][0]
            wolfi = comparison["families"][1]
            self.assertEqual(ubuntu["counts"]["occurrences"]["HIGH"], 2)
            self.assertEqual(ubuntu["counts"]["uniqueCves"]["HIGH"], 1)
            self.assertEqual(wolfi["images"][0]["sbomComponents"], 2)
            final = next(
                image
                for image in wolfi["images"]
                if image["name"] == "devcontainers/wolfi-base-toolchain:0.1.0"
            )
            tools = {item["nativeTool"] for item in final["nativeTools"]}
            self.assertEqual(tools, {"mongosh", "mongodb-database-tools"})
            boundaries = {
                item["boundary"]: item for item in comparison["boundaryComparisons"]
            }
            self.assertTrue(boundaries["toolchain-all-tools"]["comparable"])
            probe_tools = {
                item["nativeTool"] for item in comparison["probeContributions"]
            }
            self.assertIn("helm", probe_tools)
            self.assertIn("mongodb-database-tools", probe_tools)

            expected_outputs = {
                "comparison.md",
                "vulnerability-comparison.tsv",
                "native-tool-contributions.tsv",
                "package-contributions.tsv",
                "vulnerability-layer-contributions.tsv",
                "remaining-wolfi-findings.tsv",
                "image-metrics.tsv",
                "image-layer-contributions.tsv",
                "native-tool-probe-contributions.tsv",
                "equivalent-boundary-comparison.tsv",
            }
            self.assertTrue(
                all((output_dir / output).is_file() for output in expected_outputs)
            )
            self.assertFalse((output_dir / "stale-from-previous-run.tsv").exists())
            self.assertEqual(
                [
                    path.name
                    for path in temporary.iterdir()
                    if path.name.startswith(".comparison.")
                ],
                [],
            )
            metric_header = (output_dir / "image-metrics.tsv").read_text(
                encoding="utf-8"
            ).splitlines()[0]
            self.assertIn("INSTALLED_PACKAGE_COUNT", metric_header)
            self.assertIn("COMPRESSED_EXPORT_BYTES", metric_header)
            markdown = (output_dir / "comparison.md").read_text(encoding="utf-8")
            self.assertIn("Wolfi release gate: PASS", markdown)
            self.assertIn("mongosh package/runtime discrepancy", markdown)
            self.assertIn("2.9.1", markdown)

    def test_all_tools_equivalence_requires_validated_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            ubuntu_dir, wolfi_dir, policy_dir, suite_file = self.make_comparison_fixture(
                temporary
            )
            suite = json.loads(suite_file.read_text(encoding="utf-8"))
            suite["ubuntu"]["allToolsComparison"]["provenance"][
                "scanIdentityValidated"
            ] = False
            suite_file.write_text(json.dumps(suite), encoding="utf-8")

            result = subprocess.run(
                [
                    str(COMPARE_SCRIPT),
                    "--ubuntu-dir",
                    str(ubuntu_dir),
                    "--wolfi-dir",
                    str(wolfi_dir),
                    "--ubuntu-policy-dir",
                    str(policy_dir),
                    "--suite-file",
                    str(suite_file),
                    "--acceptance-file",
                    str(wolfi_dir / "acceptance.json"),
                    "--output-dir",
                    str(temporary / "comparison"),
                    "--skip-image-metrics",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("all-tools equivalence is not substantiated", result.stderr)

    def test_all_tools_equivalence_requires_every_locked_native_tool_probe(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            ubuntu_dir, wolfi_dir, policy_dir, suite_file = self.make_comparison_fixture(
                temporary
            )
            suite = json.loads(suite_file.read_text(encoding="utf-8"))
            assessment = suite["wolfi"]["nativeToolProbeAssessment"]
            assessment["requiredProbes"] = [
                probe
                for probe in assessment["requiredProbes"]
                if probe["toolKey"] != "oras"
            ]
            suite["wolfi"]["probeImages"] = [
                probe["image"] for probe in assessment["requiredProbes"]
            ]
            suite_file.write_text(json.dumps(suite), encoding="utf-8")

            result = subprocess.run(
                [
                    str(COMPARE_SCRIPT),
                    "--ubuntu-dir",
                    str(ubuntu_dir),
                    "--wolfi-dir",
                    str(wolfi_dir),
                    "--ubuntu-policy-dir",
                    str(policy_dir),
                    "--suite-file",
                    str(suite_file),
                    "--acceptance-file",
                    str(wolfi_dir / "acceptance.json"),
                    "--output-dir",
                    str(temporary / "comparison"),
                    "--skip-image-metrics",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "native-tool probe manifest differs from the current lock",
                result.stderr,
            )

    def test_comparison_rejects_suite_from_stale_wolfi_lock(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            ubuntu_dir, wolfi_dir, policy_dir, suite_file = self.make_comparison_fixture(
                temporary
            )
            suite = json.loads(suite_file.read_text(encoding="utf-8"))
            suite["wolfi"]["lockSha256"] = "0" * 64
            suite_file.write_text(json.dumps(suite), encoding="utf-8")

            result = subprocess.run(
                [
                    str(COMPARE_SCRIPT),
                    "--ubuntu-dir",
                    str(ubuntu_dir),
                    "--wolfi-dir",
                    str(wolfi_dir),
                    "--ubuntu-policy-dir",
                    str(policy_dir),
                    "--suite-file",
                    str(suite_file),
                    "--acceptance-file",
                    str(wolfi_dir / "acceptance.json"),
                    "--output-dir",
                    str(temporary / "comparison"),
                    "--skip-image-metrics",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("current exact Wolfi lock bytes", result.stderr)

    def test_comparison_rejects_probe_images_nominated_as_finals(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            ubuntu_dir, wolfi_dir, policy_dir, suite_file = self.make_comparison_fixture(
                temporary
            )
            suite = json.loads(suite_file.read_text(encoding="utf-8"))
            nominated = suite["wolfi"]["probeImages"][:3]
            suite["wolfi"]["finalImages"] = nominated
            suite["wolfi"]["boundaries"] = dict(
                zip(("dod", "vscode", "toolchain"), nominated, strict=True)
            )
            suite_file.write_text(json.dumps(suite), encoding="utf-8")

            result = subprocess.run(
                [
                    str(COMPARE_SCRIPT),
                    "--ubuntu-dir",
                    str(ubuntu_dir),
                    "--wolfi-dir",
                    str(wolfi_dir),
                    "--ubuntu-policy-dir",
                    str(policy_dir),
                    "--suite-file",
                    str(suite_file),
                    "--acceptance-file",
                    str(wolfi_dir / "acceptance.json"),
                    "--output-dir",
                    str(temporary / "comparison"),
                    "--skip-image-metrics",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("final Wolfi image manifest differs", result.stderr)

    def test_skipped_acceptance_is_not_labeled_pass(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            ubuntu_dir, wolfi_dir, policy_dir, suite_file = self.make_comparison_fixture(
                temporary
            )
            acceptance_path = wolfi_dir / "acceptance.json"
            acceptance = json.loads(acceptance_path.read_text(encoding="utf-8"))
            acceptance.update(
                {
                    "evaluated": False,
                    "passed": None,
                    "reason": "Pristine Wolfi acceptance was explicitly skipped.",
                    "occurrences": {"CRITICAL": None, "HIGH": None},
                    "uniqueCves": {"CRITICAL": None, "HIGH": None},
                    "images": [],
                }
            )
            acceptance_path.write_text(json.dumps(acceptance), encoding="utf-8")
            native_versions = temporary / "native-tool-versions.json"
            write_native_version_report(native_versions)
            output_dir = temporary / "comparison"

            subprocess.run(
                [
                    str(COMPARE_SCRIPT),
                    "--ubuntu-dir",
                    str(ubuntu_dir),
                    "--wolfi-dir",
                    str(wolfi_dir),
                    "--ubuntu-policy-dir",
                    str(policy_dir),
                    "--suite-file",
                    str(suite_file),
                    "--acceptance-file",
                    str(acceptance_path),
                    "--native-tool-version-report",
                    str(native_versions),
                    "--output-dir",
                    str(output_dir),
                    "--skip-image-metrics",
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            comparison = json.loads(
                (output_dir / "comparison.json").read_text(encoding="utf-8")
            )
            gate = comparison["releaseGate"]
            self.assertEqual(gate["status"], "NOT_EVALUATED")
            self.assertFalse(gate["evaluated"])
            self.assertFalse(gate["verified"])
            self.assertIsNone(gate["passed"])
            markdown = (output_dir / "comparison.md").read_text(encoding="utf-8")
            self.assertIn("Wolfi release gate: NOT EVALUATED", markdown)
            self.assertNotIn("Wolfi release gate: PASS", markdown)

    def test_unverified_scan_context_cannot_be_labeled_pass(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            ubuntu_dir, wolfi_dir, policy_dir, _ = self.make_comparison_fixture(
                temporary
            )
            (ubuntu_dir / "scan-metadata.json").unlink()
            (wolfi_dir / "scan-metadata.json").unlink()
            native_versions = temporary / "native-tool-versions.json"
            write_native_version_report(native_versions)
            output_dir = temporary / "comparison"

            subprocess.run(
                [
                    str(COMPARE_SCRIPT),
                    "--ubuntu-dir",
                    str(ubuntu_dir),
                    "--wolfi-dir",
                    str(wolfi_dir),
                    "--ubuntu-policy-dir",
                    str(policy_dir),
                    "--suite-file",
                    str(temporary / "missing-suite.json"),
                    "--acceptance-file",
                    str(wolfi_dir / "acceptance.json"),
                    "--native-tool-version-report",
                    str(native_versions),
                    "--output-dir",
                    str(output_dir),
                    "--allow-unverified-scan-context",
                    "--skip-image-metrics",
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            comparison = json.loads(
                (output_dir / "comparison.json").read_text(encoding="utf-8")
            )
            gate = comparison["releaseGate"]
            self.assertEqual(gate["status"], "UNVERIFIED")
            self.assertFalse(gate["verified"])
            self.assertIsNone(gate["passed"])
            self.assertTrue(gate["reportedPassed"])
            markdown = (output_dir / "comparison.md").read_text(encoding="utf-8")
            self.assertIn("Wolfi release gate: UNVERIFIED", markdown)
            self.assertNotIn("Wolfi release gate: PASS", markdown)

    def test_acceptance_counts_must_match_final_raw_reports(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            ubuntu_dir, wolfi_dir, policy_dir, suite_file = self.make_comparison_fixture(
                temporary
            )
            acceptance_path = wolfi_dir / "acceptance.json"
            acceptance = json.loads(acceptance_path.read_text(encoding="utf-8"))
            acceptance["occurrences"]["HIGH"] = 1
            acceptance_path.write_text(json.dumps(acceptance), encoding="utf-8")
            native_versions = temporary / "native-tool-versions.json"
            write_native_version_report(native_versions)
            result = subprocess.run(
                [
                    str(COMPARE_SCRIPT),
                    "--ubuntu-dir",
                    str(ubuntu_dir),
                    "--wolfi-dir",
                    str(wolfi_dir),
                    "--ubuntu-policy-dir",
                    str(policy_dir),
                    "--suite-file",
                    str(suite_file),
                    "--acceptance-file",
                    str(acceptance_path),
                    "--native-tool-version-report",
                    str(native_versions),
                    "--output-dir",
                    str(temporary / "out"),
                    "--skip-image-metrics",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("occurrence counts differ", result.stderr)

    def test_mismatched_database_snapshot_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            ubuntu_dir, wolfi_dir, policy_dir, suite_file = self.make_comparison_fixture(
                temporary
            )
            wolfi_metadata = json.loads(
                (wolfi_dir / "scan-metadata.json").read_text(encoding="utf-8")
            )
            wolfi_metadata["databaseIdentity"]["vulnerability"]["updatedAt"] = (
                "2026-09-05T01:11:59Z"
            )
            (wolfi_dir / "scan-metadata.json").write_text(
                json.dumps(wolfi_metadata), encoding="utf-8"
            )
            result = subprocess.run(
                [
                    str(COMPARE_SCRIPT),
                    "--ubuntu-dir",
                    str(ubuntu_dir),
                    "--wolfi-dir",
                    str(wolfi_dir),
                    "--ubuntu-policy-dir",
                    str(policy_dir),
                    "--suite-file",
                    str(suite_file),
                    "--output-dir",
                    str(temporary / "out"),
                    "--skip-image-metrics",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("database snapshot", result.stderr)

    def test_policy_view_with_different_image_identity_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            ubuntu_dir, wolfi_dir, policy_dir, suite_file = self.make_comparison_fixture(
                temporary
            )
            policy_metadata = json.loads(
                (policy_dir / "scan-metadata.json").read_text(encoding="utf-8")
            )
            policy_metadata["imageIdentities"][0]["imageId"] = "sha256:" + "b" * 64
            first_report = policy_dir / policy_metadata["reports"][0]["vulnerabilities"]
            first_report_payload = json.loads(first_report.read_text(encoding="utf-8"))
            first_report_payload["Metadata"]["ImageID"] = "sha256:" + "b" * 64
            first_report.write_text(json.dumps(first_report_payload), encoding="utf-8")
            policy_metadata["reports"][0]["vulnerabilitiesSha256"] = hashlib.sha256(
                first_report.read_bytes()
            ).hexdigest()
            (policy_dir / "scan-metadata.json").write_text(
                json.dumps(policy_metadata), encoding="utf-8"
            )
            result = subprocess.run(
                [
                    str(COMPARE_SCRIPT),
                    "--ubuntu-dir",
                    str(ubuntu_dir),
                    "--wolfi-dir",
                    str(wolfi_dir),
                    "--ubuntu-policy-dir",
                    str(policy_dir),
                    "--suite-file",
                    str(suite_file),
                    "--output-dir",
                    str(temporary / "out"),
                    "--skip-image-metrics",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("different image identities", result.stderr)

    def test_tampered_vulnerability_report_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            ubuntu_dir, wolfi_dir, policy_dir, suite_file = self.make_comparison_fixture(
                temporary
            )
            metadata = json.loads(
                (wolfi_dir / "scan-metadata.json").read_text(encoding="utf-8")
            )
            report = wolfi_dir / metadata["reports"][0]["vulnerabilities"]
            report.write_text(report.read_text(encoding="utf-8") + "\n", encoding="utf-8")
            result = subprocess.run(
                [
                    str(COMPARE_SCRIPT),
                    "--ubuntu-dir",
                    str(ubuntu_dir),
                    "--wolfi-dir",
                    str(wolfi_dir),
                    "--ubuntu-policy-dir",
                    str(policy_dir),
                    "--suite-file",
                    str(suite_file),
                    "--output-dir",
                    str(temporary / "out"),
                    "--skip-image-metrics",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("report hash differs", result.stderr)

    def test_empty_final_image_manifest_cannot_pass_release_gate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            ubuntu_dir, wolfi_dir, policy_dir, suite_file = self.make_comparison_fixture(
                temporary
            )
            suite = json.loads(suite_file.read_text(encoding="utf-8"))
            suite["wolfi"]["finalImages"] = []
            suite_file.write_text(json.dumps(suite), encoding="utf-8")
            result = subprocess.run(
                [
                    str(COMPARE_SCRIPT),
                    "--ubuntu-dir",
                    str(ubuntu_dir),
                    "--wolfi-dir",
                    str(wolfi_dir),
                    "--ubuntu-policy-dir",
                    str(policy_dir),
                    "--suite-file",
                    str(suite_file),
                    "--output-dir",
                    str(temporary / "out"),
                    "--skip-image-metrics",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("final Wolfi image manifest", result.stderr)


if __name__ == "__main__":
    unittest.main()
