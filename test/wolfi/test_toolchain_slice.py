#!/usr/bin/env python3
"""Static contracts for the independently buildable Wolfi toolchain slice."""

from __future__ import annotations

import json
import subprocess
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SOURCE_ROOT = REPO_ROOT / "src" / "wolfi" / "base-toolchain"
DOCKERFILE = SOURCE_ROOT / ".devcontainer" / "Dockerfile"
DEVCONTAINER = SOURCE_ROOT / ".devcontainer" / "devcontainer.json"
BUILD_SCRIPT = SOURCE_ROOT / "scripts" / "build-image.sh"
TEST_SCRIPT = SOURCE_ROOT / "scripts" / "test-image.sh"
TOP_LEVEL_TEST_SCRIPT = REPO_ROOT / "scripts" / "wolfi" / "test-all.sh"


class WolfiToolchainContracts(unittest.TestCase):
    def test_dockerfile_has_offline_core_probe_and_final_targets(self) -> None:
        content = DOCKERFILE.read_text(encoding="utf-8")
        for target in (
            "core",
            "probe-helm",
            "probe-oras",
            "probe-mongosh",
            "probe-mongodb-database-tools",
            "final",
        ):
            self.assertIn(f" AS {target}\n", content)
        for context in ("wolfi_apks", "kubectl_artifacts", "rust_artifacts"):
            self.assertIn(f"from={context}", content)
        self.assertNotIn("curl ", content)
        self.assertNotIn("wget ", content)
        self.assertNotIn("apk update", content)
        self.assertNotIn("--allow-untrusted", content)
        self.assertIn("USER ${REMOTE_USER}", content)

    def test_devcontainer_preserves_identity_without_duplicating_build_lock(self) -> None:
        config = json.loads(DEVCONTAINER.read_text(encoding="utf-8"))
        self.assertEqual(config["containerUser"], "root")
        self.assertEqual(config["remoteUser"], "vscode")
        self.assertTrue(config["updateRemoteUserUID"])
        self.assertTrue(config["init"])
        self.assertNotIn("build", config)
        self.assertEqual(config["image"], "devcontainers/wolfi-base-toolchain:0.1.0")

    def test_scripts_parse_and_document_frozen_inputs(self) -> None:
        for script in sorted((SOURCE_ROOT / "scripts").glob("*.sh")):
            subprocess.run(["bash", "-n", str(script)], check=True)
        help_result = subprocess.run(
            [str(BUILD_SCRIPT), "--help"],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("--network=none", help_result.stdout)
        self.assertIn("--rust-archive-sha256", help_result.stdout)
        self.assertIn("--kubectl-hash", help_result.stdout)

    def test_full_suite_exercises_the_frozen_apk_install(self) -> None:
        content = TOP_LEVEL_TEST_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            'src/wolfi/apk-artifacts/scripts/test-offline-install.sh', content
        )
        self.assertIn('--config-sha256 "${CONFIG_HASH}"', content)
        self.assertIn('--artifact-root "${ARTIFACT_ROOT}"', content)

    def test_optional_yaml_tools_control_targets_and_install_steps(self) -> None:
        build = BUILD_SCRIPT.read_text(encoding="utf-8")
        dockerfile = DOCKERFILE.read_text(encoding="utf-8")
        tests = TEST_SCRIPT.read_text(encoding="utf-8")
        for key in ("kubectl", "rust", "helm", "oras", "mongosh", "mongodbDatabaseTools"):
            self.assertIn(f"tool_enabled {key}", build)
        self.assertIn('[[ "${HELM_ENABLED}" == true ]] && all_targets+=(probe-helm)', build)
        self.assertIn("Enabled tool has no authoritative locked APK package set", build)
        self.assertIn('if [ "${WOLFI_INSTALL_KUBECTL}" = true ]', dockerfile)
        self.assertIn('if [ "${WOLFI_INSTALL_RUST}" = true ]', dockerfile)
        self.assertIn('if [ "${WOLFI_INSTALL_NATIVE_TOOLS}" = true ]', dockerfile)
        self.assertIn(".config.toolchain.helm // empty", tests)

    def test_all_toolchain_targets_inherit_exact_lock_provenance(self) -> None:
        dockerfile = DOCKERFILE.read_text(encoding="utf-8")
        build = BUILD_SCRIPT.read_text(encoding="utf-8")
        tests = TEST_SCRIPT.read_text(encoding="utf-8")
        self.assertIn("ARG WOLFI_LOCK_SHA256", dockerfile)
        self.assertIn(
            'LABEL devcontainers.wolfi.lock.sha256="${WOLFI_LOCK_SHA256}"',
            dockerfile,
        )
        self.assertIn("LOCK_SHA256=\"$(wolfi_lock_sha256", build)
        self.assertIn('--build-arg "WOLFI_LOCK_SHA256=${LOCK_SHA256}"', build)
        self.assertIn('wolfi_verify_image_lock "${BASE_IMAGE}"', build)
        self.assertIn('wolfi_verify_image_lock "${output_image}"', build)
        self.assertIn('wolfi_verify_image_lock "${image}"', tests)

    def test_rust_payload_is_hardened_but_cargo_state_is_user_writable(self) -> None:
        dockerfile = DOCKERFILE.read_text(encoding="utf-8")
        installer = (SOURCE_ROOT / "scripts" / "install-rust.sh").read_text(encoding="utf-8")
        self.assertIn("CARGO_HOME=/home/${REMOTE_USER}/.cargo", dockerfile)
        self.assertIn("/home/${REMOTE_USER}/.cargo/bin:/usr/local/cargo/bin", dockerfile)
        self.assertIn("unsupported archive member type", installer)
        self.assertIn("symlink crosses payload roots", installer)
        self.assertIn("set-id or world-writable mode", installer)

    def test_smoke_suite_covers_requested_native_and_compiler_tools(self) -> None:
        content = TEST_SCRIPT.read_text(encoding="utf-8")
        for command in (
            'python_command="python${version}"',
            'PYTHON_SELECTORS="$(jq',
            "mvn --offline",
            "corepack --version",
            "clang++",
            "kubectl version",
            "helm lint",
            "oras push --oci-layout",
            "mongosh --nodb",
            "mongodump",
            "cargo test --offline",
            "clamscan --version",
        ):
            self.assertIn(command, content)
        self.assertIn("packageRuntimeVersionDiscrepancy", content)
        self.assertIn("! command -v \"${forbidden_command}\"", content)


if __name__ == "__main__":
    unittest.main()
