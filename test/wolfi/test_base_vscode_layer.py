#!/usr/bin/env python3
"""Static contract tests for the Wolfi VS Code image layer."""

from __future__ import annotations

import json
import subprocess
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SOURCE_ROOT = REPO_ROOT / "src" / "wolfi" / "base-vscode"


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

    def test_shell_scripts_parse(self) -> None:
        for script in sorted((SOURCE_ROOT / "scripts").glob("*.sh")):
            with self.subTest(script=script.name):
                subprocess.run(["bash", "-n", str(script)], check=True)


if __name__ == "__main__":
    unittest.main()
