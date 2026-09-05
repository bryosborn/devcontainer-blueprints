#!/usr/bin/env python3
"""Static contract tests for the Wolfi VS Code image layer."""

from __future__ import annotations

import json
import subprocess
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SOURCE_ROOT = REPO_ROOT / "src" / "wolfi" / "base-vscode"
DOD_ROOT = REPO_ROOT / "src" / "wolfi" / "base-dod"


class WolfiBaseVscodeLayerTests(unittest.TestCase):
    def test_devcontainer_identity_contract(self) -> None:
        config = json.loads(
            (SOURCE_ROOT / ".devcontainer" / "devcontainer.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(config["containerUser"], "root")
        self.assertEqual(config["remoteUser"], "vscode")
        self.assertIs(config["updateRemoteUserUID"], True)
        self.assertIs(config["init"], True)

    def test_dockerfile_keeps_extensions_uninstalled(self) -> None:
        dockerfile = (SOURCE_ROOT / ".devcontainer" / "Dockerfile").read_text(
            encoding="utf-8"
        )
        self.assertIn("FROM ${BASE_IMAGE}", dockerfile)
        self.assertIn("vscode-extensions.tar.gz", dockerfile)
        self.assertIn("install-vscode-extensions.sh", dockerfile)
        self.assertNotIn("--install-extension", dockerfile)
        self.assertIn("-mindepth 1", dockerfile)
        self.assertIn("USER ${REMOTE_USER}", dockerfile)

    def test_dockerfile_uses_only_offline_build_inputs(self) -> None:
        dockerfile = (SOURCE_ROOT / ".devcontainer" / "Dockerfile").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("curl ", dockerfile)
        self.assertNotIn("wget ", dockerfile)
        self.assertNotIn("https://", dockerfile)
        self.assertIn("from=wolfi_apks", dockerfile)
        self.assertIn("from=vscode_server", dockerfile)
        self.assertIn("from=vscode_extensions", dockerfile)

    def test_dod_and_vscode_images_bind_to_exact_lock_bytes(self) -> None:
        for source_root in (DOD_ROOT, SOURCE_ROOT):
            with self.subTest(layer=source_root.name):
                dockerfile = (
                    source_root / ".devcontainer" / "Dockerfile"
                ).read_text(encoding="utf-8")
                build_script = (source_root / "scripts" / "build-image.sh").read_text(
                    encoding="utf-8"
                )
                image_test = (source_root / "scripts" / "test-image.sh").read_text(
                    encoding="utf-8"
                )
                self.assertIn("ARG WOLFI_LOCK_SHA256", dockerfile)
                self.assertIn(
                    'LABEL devcontainers.wolfi.lock.sha256="${WOLFI_LOCK_SHA256}"',
                    dockerfile,
                )
                self.assertIn("LOCK_SHA256=\"$(wolfi_lock_sha256", build_script)
                self.assertIn("WOLFI_LOCK_SHA256", build_script)
                self.assertIn("wolfi_verify_image_lock", build_script)
                self.assertIn("wolfi_verify_image_lock", image_test)

    def test_shell_scripts_parse(self) -> None:
        for script in sorted((SOURCE_ROOT / "scripts").glob("*.sh")):
            with self.subTest(script=script.name):
                subprocess.run(["bash", "-n", str(script)], check=True)

    def test_disposable_extension_component_smoke_is_explicit_and_honest(self) -> None:
        image_test = (SOURCE_ROOT / "scripts" / "test-image.sh").read_text(
            encoding="utf-8"
        )
        component_test = SOURCE_ROOT / "scripts" / "test-extension-components.mjs"
        component_source = component_test.read_text(encoding="utf-8")

        self.assertIn("--test-extension-components", image_test)
        self.assertIn("--network=none", image_test)
        self.assertIn("test-extension-components.mjs", image_test)
        for extension_id in (
            "ms-python.debugpy",
            "ms-vscode.cpptools",
            "rust-lang.rust-analyzer",
            "redhat.java",
            "redhat.vscode-yaml",
            "redhat.vscode-xml",
            "ms-azuretools.vscode-containers",
        ):
            self.assertIn(extension_id, component_source)
        self.assertIn("not full VS Code extension-host activation", component_source)
        subprocess.run(["node", "--check", str(component_test)], check=True)


if __name__ == "__main__":
    unittest.main()
