#!/usr/bin/env python3
"""Isolated contracts for the disposable Ubuntu comparison image provenance."""

from __future__ import annotations

import hashlib
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
BUILD_SCRIPT = REPO_ROOT / "scripts" / "wolfi" / "build-ubuntu-all-tools.sh"
HELPER = REPO_ROOT / "scripts" / "wolfi" / "ubuntu-comparator-provenance.sh"
DOCKERFILE = (
    REPO_ROOT / "scripts" / "wolfi" / "Dockerfile.ubuntu-comparator-provenance"
)
SCAN_SCRIPT = REPO_ROOT / "scripts" / "wolfi" / "scan.sh"
LABEL_PREFIX = "devcontainers.ubuntu.comparator"


def hash_named_files(*pairs: tuple[str, Path]) -> subprocess.CompletedProcess[str]:
    arguments = " ".join(
        f"{logical_name!r} {str(file_path)!r}" for logical_name, file_path in pairs
    )
    return subprocess.run(
        [
            "bash",
            "-c",
            f"source {str(HELPER)!r}; ubuntu_comparator_hash_named_files {arguments}",
        ],
        capture_output=True,
        text=True,
        check=False,
    )


class UbuntuComparatorProvenanceTests(unittest.TestCase):
    def test_effective_overlays_force_complete_all_tools_profile(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            docker_config = temporary / "docker.env"
            docker_config.write_text(
                "\n".join(
                    [
                        "BASE_TOOLCHAIN_IMAGE=old:tag",
                        "BASE_TOOLCHAIN_INSTALL_APT=${BASE_TOOLCHAIN_INSTALL_APT:-false}",
                        "BASE_TOOLCHAIN_INSTALL_PYTHON_PIP=false",
                        "BASE_TOOLCHAIN_INSTALL_JAVA_MAVEN=0",
                        "BASE_TOOLCHAIN_INSTALL_NODE=no",
                        "BASE_TOOLCHAIN_INSTALL_CLI_TOOLS=off",
                        "BASE_TOOLCHAIN_INSTALL_MONGODB_TOOLS=false",
                        "BASE_TOOLCHAIN_INSTALL_RUST=false",
                        "APT_PACKAGE_LIST=src/apt-artifacts/apt-packages.txt",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            toolchain_config = temporary / "toolchain.env"
            toolchain_config.write_text(
                "HELM_INSTALL=false\nORAS_INSTALL=false\n"
                "MONGODB_DATABASE_TOOLS_INSTALL=false\n",
                encoding="utf-8",
            )
            command = (
                f"source {str(HELPER)!r}; "
                f"ubuntu_comparator_effective_docker_config new/image:tag {str(docker_config)!r}; "
                f"ubuntu_comparator_effective_toolchain_config {str(toolchain_config)!r}"
            )
            result = subprocess.run(
                ["bash", "-c", command], capture_output=True, text=True, check=False
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("BASE_TOOLCHAIN_IMAGE=new/image:tag", result.stdout)
            self.assertIn(
                "APT_PACKAGE_LIST=${UBUNTU_COMPARATOR_APT_PACKAGE_LIST:",
                result.stdout,
            )
            for variable in (
                "BASE_TOOLCHAIN_INSTALL_APT",
                "BASE_TOOLCHAIN_INSTALL_PYTHON_PIP",
                "BASE_TOOLCHAIN_INSTALL_JAVA_MAVEN",
                "BASE_TOOLCHAIN_INSTALL_NODE",
                "BASE_TOOLCHAIN_INSTALL_CLI_TOOLS",
                "BASE_TOOLCHAIN_INSTALL_MONGODB_TOOLS",
                "BASE_TOOLCHAIN_INSTALL_RUST",
                "HELM_INSTALL",
                "ORAS_INSTALL",
                "MONGODB_DATABASE_TOOLS_INSTALL",
            ):
                self.assertIn(f"{variable}=true", result.stdout)

    def test_effective_apt_roots_follow_wolfi_clamav_presence_only(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            package_list = temporary / "apt-packages.txt"
            package_list.write_text(
                "# roots\nclamav\nclamav-daemon\ncmake\n", encoding="utf-8"
            )
            disabled_lock = temporary / "disabled.json"
            disabled_lock.write_text(
                '{"schemaVersion":1,"config":{"toolchain":{"cmake":"latest"}}}',
                encoding="utf-8",
            )
            enabled_lock = temporary / "enabled.json"
            enabled_lock.write_text(
                '{"schemaVersion":1,"config":{"toolchain":{"clamav":"1.5"}}}',
                encoding="utf-8",
            )

            def effective(lock: Path) -> subprocess.CompletedProcess[str]:
                return subprocess.run(
                    [
                        "bash",
                        "-c",
                        f"source {str(HELPER)!r}; "
                        f"ubuntu_comparator_effective_apt_package_list "
                        f"{str(lock)!r} {str(package_list)!r}",
                    ],
                    capture_output=True,
                    text=True,
                    check=False,
                )

            disabled = effective(disabled_lock)
            enabled = effective(enabled_lock)
            self.assertEqual(disabled.returncode, 0, disabled.stderr)
            self.assertEqual(enabled.returncode, 0, enabled.stderr)
            self.assertEqual(disabled.stdout, "# roots\nclamav-daemon\ncmake\n")
            self.assertEqual(enabled.stdout, package_list.read_text(encoding="utf-8"))

    def test_effective_apt_roots_require_one_unambiguous_clamav_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            lock = temporary / "lock.json"
            lock.write_text(
                '{"schemaVersion":1,"config":{"toolchain":{}}}', encoding="utf-8"
            )
            for content in ("cmake\n", "clamav\nclamav\n"):
                package_list = temporary / "apt-packages.txt"
                package_list.write_text(content, encoding="utf-8")
                result = subprocess.run(
                    [
                        "bash",
                        "-c",
                        f"source {str(HELPER)!r}; "
                        f"ubuntu_comparator_effective_apt_package_list "
                        f"{str(lock)!r} {str(package_list)!r}",
                    ],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertNotEqual(result.returncode, 0)

    def test_named_file_hash_is_canonical_and_content_sensitive(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            first = temporary / "first"
            second = temporary / "second"
            first.write_bytes(b"first\n")
            second.write_bytes(b"second\n")

            first_hash = hashlib.sha256(first.read_bytes()).hexdigest()
            second_hash = hashlib.sha256(second.read_bytes()).hexdigest()
            canonical_manifest = (
                f"a/first\t{first_hash}\n" f"b/second\t{second_hash}\n"
            ).encode()
            expected = hashlib.sha256(canonical_manifest).hexdigest()

            forward = hash_named_files(("a/first", first), ("b/second", second))
            reverse = hash_named_files(("b/second", second), ("a/first", first))
            self.assertEqual(forward.returncode, 0, forward.stderr)
            self.assertEqual(reverse.returncode, 0, reverse.stderr)
            self.assertEqual(forward.stdout.strip(), expected)
            self.assertEqual(reverse.stdout.strip(), expected)

            second.write_bytes(b"changed\n")
            changed = hash_named_files(("a/first", first), ("b/second", second))
            self.assertEqual(changed.returncode, 0, changed.stderr)
            self.assertNotEqual(changed.stdout.strip(), expected)

    def test_named_file_hash_rejects_ambiguous_or_unsafe_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            regular = temporary / "regular"
            regular.write_text("content", encoding="utf-8")
            symlink = temporary / "symlink"
            symlink.symlink_to(regular)

            duplicate = hash_named_files(("same", regular), ("same", regular))
            linked = hash_named_files(("linked", symlink))
            missing = hash_named_files(("missing", temporary / "absent"))
            invalid = hash_named_files(("../escape", regular))
            for result in (duplicate, linked, missing, invalid):
                self.assertNotEqual(result.returncode, 0)

    def test_builder_applies_and_verifies_complete_label_contract(self) -> None:
        content = BUILD_SCRIPT.read_text(encoding="utf-8")
        suffixes = (
            "schema-version",
            "image.ref",
            "platform",
            "source-image.ref",
            "source-image.id",
            "payload-image.id",
            "payload-rootfs.sha256",
            "docker-config.sha256",
            "toolchain-config.sha256",
            "effective-docker-config.sha256",
            "effective-toolchain-config.sha256",
            "wolfi-lock.sha256",
            "apt-package-roots.sha256",
            "recipe.sha256",
            "artifact-manifests.sha256",
        )
        for suffix in suffixes:
            self.assertIn(f'UBUNTU_COMPARATOR_LABEL_PREFIX}}.{suffix}=', content)
        self.assertIn('provenance_label_args+=(--label "${provenance_label}")', content)
        self.assertIn('actual_label_value="$(\n    docker image inspect', content)
        self.assertIn('--network=none', content)
        self.assertIn('--pull=false', content)
        self.assertIn('source_image_id_after=', content)
        self.assertIn('docker image tag "${payload_image_id}"', content)
        self.assertIn('actual_prefix_label_count=', content)
        self.assertIn('Ubuntu comparator inputs changed during the payload build', content)
        self.assertLess(
            content.index('if [[ "${PREFETCH}" == true ]]'),
            content.index('artifact_manifests_sha256="$('),
        )

    def test_scanner_admits_only_current_provenance_and_binds_scanned_id(self) -> None:
        content = SCAN_SCRIPT.read_text(encoding="utf-8")
        self.assertIn('ubuntu_all_tools_provenance_valid()', content)
        self.assertIn('UBUNTU_ALL_TOOLS_ADMITTED_IMAGE_ID', content)
        self.assertIn('"${admitted_image_id}" -c', content)
        self.assertIn('Comparator provenance label set is incomplete', content)
        self.assertIn('payload-rootfs.sha256=', content)
        self.assertIn('apt-package-roots.sha256=', content)
        self.assertIn('EXPECTED_CLAMAV_ENABLED=', content)
        self.assertIn('! command -v clamscan', content)
        self.assertIn('Scanned Ubuntu comparator/source identity differs', content)
        self.assertIn('.scanIdentityValidated = true', content)
        self.assertIn('$ubuntuAllToolsProvenance.validated == true', content)
        self.assertIn(
            '$ubuntuAllToolsProvenance.scanIdentityValidated == true', content
        )
        self.assertLess(
            content.index('rm -f "${SUITE_FILE}"'),
            content.index('if [[ "${RUN_UBUNTU}" == true ]]; then'),
        )

    def test_metadata_dockerfile_is_metadata_only(self) -> None:
        content = DOCKERFILE.read_text(encoding="utf-8")
        directives = [
            line.split(maxsplit=1)[0].upper()
            for line in content.splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ]
        self.assertEqual(directives, ["ARG", "FROM"])
        self.assertIn("FROM ${SOURCE_IMAGE}", content)

    def test_scripts_parse(self) -> None:
        for script in (BUILD_SCRIPT, HELPER, SCAN_SCRIPT):
            with self.subTest(script=script.name):
                subprocess.run(["bash", "-n", str(script)], check=True)


if __name__ == "__main__":
    unittest.main()
