#!/usr/bin/env python3
"""Profile selection tests independent of a Docker daemon and online indexes."""

from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "src/wolfi/apk-artifacts/scripts"
sys.path.insert(0, str(SCRIPTS))

from supply_lib import (  # noqa: E402
    SupplyError,
    expand_package_roots,
    load_package_mapping,
    roots_for_modules,
    validate_selected_package_set,
)


def load_module(filename: str):
    spec = importlib.util.spec_from_file_location(filename.removesuffix(".py"), SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ApkProfileTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.mapping = load_package_mapping(SCRIPTS.parent / "package-roots.json")
        cls.profiles = {
            name: json.loads(subprocess.check_output([
                "node", str(ROOT / "scripts/wolfi/config.mjs"), "print-json",
                str(ROOT / f"config/wolfi-{name}.yaml"),
            ], text=True))
            for name in ("ci", "dev")
        }

    def roots(self, config):
        roots, sets = expand_package_roots(config, self.mapping)
        self.assertEqual(set(sets), {"final"})
        return roots_for_modules(roots, sets["final"]), sets["final"]

    def locked_set(self, config):
        roots, modules = self.roots(config)
        return {"final": {
            "modules": modules,
            "roots": [{
                "module": root["module"], "requestedName": root["name"],
                "repository": root["repository"], "requestedSelector": root["selector"],
            } for root in roots],
        }}

    def test_ci_has_tools_without_dev_runtime_roots(self):
        roots, modules = self.roots(self.profiles["ci"])
        names = {root["name"] for root in roots}
        self.assertEqual(modules, ["base", "build", "utilities", "playwright"])
        self.assertTrue({"bash", "grep", "git", "jq", "gnutar", "gzip"} <= names)
        self.assertTrue({"docker-cli", "docker-cli-buildx", "docker-compose", "socat", "sudo", "shadow"}.isdisjoint(names))

    def test_profiles_share_toolchain_package_roots(self):
        roots = {
            name: [root for root in self.roots(config)[0] if root["module"] in {"build", "utilities"}]
            for name, config in self.profiles.items()
        }
        self.assertEqual(roots["ci"], roots["dev"])

    def test_socket_false_keeps_cli_without_proxy(self):
        config = copy.deepcopy(self.profiles["dev"])
        config["docker"]["socket"] = False
        names = {root["name"] for root in self.roots(config)[0]}
        self.assertIn("docker-cli", names)
        self.assertNotIn("socat", names)

    def test_editor_and_user_are_independent_of_docker(self):
        config = copy.deepcopy(self.profiles["dev"])
        del config["docker"]
        roots, modules = self.roots(config)
        names = {root["name"] for root in roots}
        self.assertIn("vscode", modules)
        self.assertIn("shadow", names)
        self.assertTrue({"docker-cli", "docker-compose", "socat"}.isdisjoint(names))

    def test_minimal_profile_has_only_base_roots(self):
        config = copy.deepcopy(self.profiles["ci"])
        config["build"] = {}
        config["utilities"] = {}
        del config["playwright"]
        roots, modules = self.roots(config)
        self.assertEqual(modules, ["base"])
        self.assertTrue(all(root["module"] == "base" for root in roots))

    def test_build_basics_do_not_require_clang(self):
        config = copy.deepcopy(self.profiles["ci"])
        config["build"] = {"native": {}}
        names = {root["name"] for root in self.roots(config)[0]}
        self.assertTrue({"build-base", "cmake", "openssl-dev"} <= names)
        self.assertNotIn("clang-22", names)

    def test_rust_only_has_native_linker_without_clang_or_cmake(self):
        config = copy.deepcopy(self.profiles["ci"])
        config["build"] = {"rust": config["build"]["rust"]}
        names = {root["name"] for root in self.roots(config)[0]}
        self.assertIn("build-base", names)
        self.assertTrue({"clang-22", "cmake", "openssl-dev"}.isdisjoint(names))

    def test_default_rust_and_build_have_one_build_base_root(self):
        for config in self.profiles.values():
            names = [root["name"] for root in self.roots(config)[0]]
            self.assertEqual(names.count("build-base"), 1)

    def test_frozen_selection_rejects_omitted_extra_or_stale_roots(self):
        config = self.profiles["ci"]
        selected = self.locked_set(config)
        validate_selected_package_set(config, selected)
        for invalid in [
            {"core": selected["final"]},
            {**selected, "probe-helm": selected["final"]},
            self.locked_set(self.profiles["dev"]),
        ]:
            with self.assertRaises(SupplyError):
                validate_selected_package_set(config, invalid)
        selected["final"]["roots"].pop()
        with self.assertRaisesRegex(SupplyError, "roots differ"):
            validate_selected_package_set(config, selected)

    def test_reviewed_utilities_are_optional_signed_native_roots(self):
        config = {"build": {}, "utilities": {"curl": "latest", "openssh-client": "latest"}}
        names = {root["name"] for root in self.roots(config)[0]}
        self.assertTrue({"curl", "openssh-client"} <= names)
        self.assertTrue({"openssh", "openssh-server", "zip", "bind-tools"}.isdisjoint(names))

    def test_duplicate_roots_preserve_a_pin_and_reject_conflicting_pins(self):
        def root(module, selector):
            return {"module": module, "name": "curl", "repository": "main", "selector": selector, "validateSelector": True}
        for roots in [[root("a", "8.22"), root("b", "latest")], [root("a", "latest"), root("b", "8.22")]]:
            self.assertEqual(roots_for_modules(roots, ["a", "b"])[0]["selector"], "8.22")
        with self.assertRaisesRegex(SupplyError, "conflicting selectors"):
            roots_for_modules([root("a", "8.22"), root("b", "8.21")], ["a", "b"])

    def test_one_closure_records_exact_selected_root_constraints(self):
        resolver = load_module("resolve-apks.py")
        config = copy.deepcopy(self.profiles["ci"])
        config["build"] = {}
        config["utilities"] = {}
        roots, modules = self.roots(config)
        packages = [{
            "id": f"main:{root['name']}=1.0-r0", "name": root["name"],
            "repository": "main", "version": "1.0-r0", "provides": [],
            "constraint": f"{root['name']}=1.0-r0",
        } for root in roots]
        targets = [("main", f"{package['name']}-1.0-r0.apk") for package in packages]
        result = resolver.build_package_set_records(
            roots=roots, package_sets={"final": modules}, closures={"final": targets},
            packages=packages, id_by_target={target: package["id"] for target, package in zip(targets, packages)},
            artifact_directory="artifacts/wolfi/ci/linux-amd64/apk",
        )
        self.assertEqual(set(result), {"final"})
        self.assertEqual(result["final"]["packages"], [package["constraint"] for package in packages])
        self.assertEqual(set(result["final"]["closure"]), {package["id"] for package in packages})
        validate_selected_package_set(config, result)

    def test_offline_test_retains_base_world_and_installed_database(self):
        installer = load_module("test-offline-install.py")
        package = {"id": "main:bash=1", "name": "bash", "version": "1", "repository": "main", "file": "repositories/main/x86_64/bash-1.apk"}
        script, expected = installer.build_test_script(
            apk={"repositories": {"main": {"indexFile": "repositories/main/x86_64/APKINDEX.tar.gz"}}, "packageSets": {"final": {"closure": [package["id"]], "packages": ["bash=1"]}}},
            packages_by_id={package["id"]: package}, architecture="x86_64",
        )
        self.assertIn("cp /etc/apk/world", script)
        self.assertIn("cp /lib/apk/db/installed", script)
        self.assertIn("--no-network", script)
        self.assertEqual(expected, {"final": {"bash-1"}})


class OfflineSupplyTests(unittest.TestCase):
    def setUp(self):
        self.frozen = load_module("prefetch-frozen.py")
        self.temporary = tempfile.TemporaryDirectory(prefix="wolfi-offline-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_missing_package_cannot_download_in_offline_mode(self):
        with mock.patch.object(self.frozen, "download") as download:
            with self.assertRaisesRegex(SupplyError, "missing in offline mode"):
                self.frozen.fetch_missing_locked_file(
                    self.root / "missing.apk", url="https://example.test/pkg.apk",
                    expected_hash="a" * 64, expected_size=10, location="APK", offline=True,
                )
            download.assert_not_called()

    def test_existing_offline_bytes_still_require_exact_hash(self):
        file = self.root / "pkg.apk"
        file.write_bytes(b"verified bytes")
        expected = hashlib.sha256(file.read_bytes()).hexdigest()
        kwargs = dict(url="https://example.test/pkg.apk", expected_hash=expected,
                      expected_size=file.stat().st_size, location="APK", offline=True)
        with mock.patch.object(self.frozen, "download") as download:
            self.assertFalse(self.frozen.fetch_missing_locked_file(file, **kwargs))
            file.write_bytes(b"modified bytes")
            with self.assertRaisesRegex(SupplyError, "SHA256 mismatch"):
                self.frozen.fetch_missing_locked_file(file, **kwargs)
            download.assert_not_called()

    def base_artifact(self):
        return {"file": "base.tar", "localReference": "local/base:test",
                "pinnedReference": "registry.test/base@sha256:" + "a" * 64,
                "digest": "sha256:" + "a" * 64, "sha256": "b" * 64, "size": 10}

    def test_missing_base_archive_cannot_be_rematerialized_offline(self):
        with mock.patch.object(self.frozen, "inspect_local_base", return_value=None), \
                mock.patch.object(self.frozen, "regenerate_base_artifact") as regenerate:
            with self.assertRaisesRegex(SupplyError, "missing in offline mode"):
                self.frozen.ensure_base_image(artifact=self.base_artifact(), platform_root=self.root,
                                              platform="linux/amd64", offline=True)
            regenerate.assert_not_called()

    def test_verified_saved_base_can_be_loaded_offline(self):
        (self.root / "base.tar").write_bytes(b"saved image")
        with mock.patch.object(self.frozen, "inspect_local_base", side_effect=[None, {"Id": "sha256:c"}]), \
                mock.patch.object(self.frozen, "verify_file") as verify_file, \
                mock.patch.object(self.frozen, "verify_base_archive", return_value={"sha256:c"}) as verify_archive, \
                mock.patch.object(self.frozen, "verify_local_base") as verify_loaded, \
                mock.patch.object(self.frozen, "run") as run:
            self.frozen.ensure_base_image(artifact=self.base_artifact(), platform_root=self.root,
                                          platform="linux/amd64", offline=True)
            verify_file.assert_called_once()
            verify_archive.assert_called_once()
            run.assert_called_once_with(["docker", "image", "load", "--input", str(self.root / "base.tar")])
            self.assertEqual(verify_loaded.call_args.kwargs["expected_image_ids"], {"sha256:c"})


if __name__ == "__main__":
    unittest.main()
