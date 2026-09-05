"""Offline checks for Playwright artifact binding and safe installation."""
import base64
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("playwright_supply", ROOT / "src/supply/vendor/playwright_supply.py")
supply = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(supply)


class PlaywrightSupplyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="wolfi-playwright-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.config = {"playwright": {"version": "1.63.0"}, "image": {"platform": "linux/amd64"},
                       "artifacts": {"root": "artifacts/profile"}}
        self.directory = self.root / "artifacts/profile/linux-amd64/vendor/playwright/1.63.0"
        self.directory.mkdir(parents=True)

    def file_record(self, filename):
        path = self.directory / filename
        return {"file": path.relative_to(self.root).as_posix(), "sha256": supply.sha256(path),
                "size": path.stat().st_size, "url": "https://example.invalid/" + filename}

    def fixture(self):
        packages = []
        for index, name in enumerate(supply.PACKAGES):
            path = self.directory / f"package-{index}.tgz"
            dependencies = {"@playwright/test": {"playwright": "1.63.0"},
                            "playwright": {"playwright-core": "1.63.0"}, "playwright-core": {}}[name]
            data = json.dumps({"name": name, "version": "1.63.0", "dependencies": dependencies}).encode()
            with tarfile.open(path, "w:gz") as archive:
                entry = tarfile.TarInfo("package/package.json")
                entry.size = len(data)
                archive.addfile(entry, io.BytesIO(data))
            packages.append({"name": name, "version": "1.63.0", **self.file_record(path.name),
                             "integrity": "sha512-" + base64.b64encode(hashlib.sha512(path.read_bytes()).digest()).decode()})
        browsers = []
        header = bytearray(20)
        header[:6] = bytes([127, 69, 76, 70, 2, 1])
        header[18] = 62
        for name in supply.BROWSERS:
            path = self.directory / (name + ".zip")
            with zipfile.ZipFile(path, "w") as archive:
                entry = zipfile.ZipInfo("chrome-linux/chrome")
                entry.external_attr = (stat.S_IFREG | 0o755) << 16
                archive.writestr(entry, header)
                archive.writestr("chrome-linux/LICENSE", "fixture license")
            browsers.append({"name": name, "revision": "1243", "browserVersion": "153.0.8010.12",
                             "cacheDirectory": name.replace("-", "_") + "-1243",
                             "archiveDirectory": "chrome-linux", "executable": "chrome-linux/chrome",
                             **self.file_record(path.name)})
        record = {"schemaVersion": 1, "version": "1.63.0", "platform": "linux/amd64",
                  "cachePath": supply.CACHE_PATH, "video": False, "browserVersion": "153.0.8010.12",
                  "packages": packages, "browsers": browsers,
                  "archive": {"file": (self.directory / "runtime.tar.gz").relative_to(self.root).as_posix()},
                  "testRunner": {"file": (self.directory / "runner.tar.gz").relative_to(self.root).as_posix()}}
        supply.materialize(record, self.root)
        for key in ("archive", "testRunner"):
            record[key] = {k: v for k, v in self.file_record(Path(record[key]["file"]).name).items() if k != "url"}
        return record

    def verify_fetch(self, url, path, expected, offline=False):
        self.assertTrue(offline)
        self.assertTrue(url.startswith("https://"))
        if not path.exists() or supply.sha256(path) != expected:
            raise SystemExit("offline SHA256 mismatch or missing input")

    def test_frozen_reconstruction_is_deterministic_and_excludes_video_and_global_runner(self):
        record = self.fixture()
        expected = {key: (self.root / record[key]["file"]).read_bytes() for key in ("archive", "testRunner")}
        for key in expected:
            (self.root / record[key]["file"]).unlink()
        previous = os.umask(0o077)
        try:
            with patch.object(supply, "verify_registry"):
                supply.prefetch(record, self.root, self.verify_fetch, offline=True, config=self.config)
        finally:
            os.umask(previous)
        for key in expected:
            self.assertEqual((self.root / record[key]["file"]).read_bytes(), expected[key])
        with tarfile.open(self.root / record["archive"]["file"]) as archive:
            names = archive.getnames()
            self.assertNotIn("node_modules", names)
            self.assertFalse(any("ffmpeg" in name or "DEPENDENCIES_VALIDATED" in name for name in names))
            self.assertTrue(any(name.endswith("INSTALLATION_COMPLETE") for name in names))
            self.assertTrue(all(entry.uid == 0 and entry.gid == 0 and not entry.mode & 0o6002 for entry in archive))

    def test_record_is_bound_to_selected_version_platform_profile_and_both_browsers(self):
        record = self.fixture()
        supply.validate_record(record, self.config)
        changes = [lambda r: r.update(version="1.62.1"), lambda r: r.update(platform="linux/arm64"),
                   lambda r: r["browsers"].pop(), lambda r: r.update(video=True),
                   lambda r: r["archive"].update(file="artifacts/other/runtime.tar.gz"),
                   lambda r: r["browsers"][0].update(cacheDirectory="../../escape")]
        for mutate in changes:
            candidate = copy.deepcopy(record)
            mutate(candidate)
            with self.assertRaises(SystemExit):
                supply.validate_record(candidate, self.config)

    def test_tampered_artifact_and_wrong_npm_integrity_fail_without_resolution(self):
        record = self.fixture()
        with patch.object(supply, "fetch_bytes", side_effect=AssertionError("mutable resolution")):
            record["packages"][0]["integrity"] = "sha512-" + base64.b64encode(b"a" * 64).decode()
            with self.assertRaisesRegex(SystemExit, "integrity mismatch"):
                supply.prefetch(record, self.root, self.verify_fetch, offline=True, config=self.config)
        record = self.fixture()
        (self.root / record["archive"]["file"]).write_bytes(b"tampered")
        with patch.object(supply, "verify_registry"), self.assertRaisesRegex(SystemExit, "SHA256 mismatch"):
            supply.prefetch(record, self.root, self.verify_fetch, offline=True, config=self.config)

    def test_browser_archives_reject_traversal_and_symlinks(self):
        for filename, mode in [("../../escape", stat.S_IFREG | 0o644), ("chrome-linux/link", stat.S_IFLNK | 0o777)]:
            archive = self.root / "unsafe.zip"
            with zipfile.ZipFile(archive, "w") as payload:
                entry = zipfile.ZipInfo(filename)
                entry.external_attr = mode << 16
                payload.writestr(entry, "../../escape")
            with self.assertRaises(SystemExit):
                supply.unpack_browser(archive, self.root / "unpacked", {"executable": "chrome-linux/chrome"})
            self.assertFalse((self.root.parent / "escape").exists())

    def test_registry_selection_sanitizes_npm_environment_aliases_for_foreign_architecture(self):
        cache = self.root / "browser-cache"
        selected = [{"name": name, "revision": "1243", "browserVersion": "153.0.8010.12",
                     "directory": str(cache / (name.replace("-", "_") + "-1243")),
                     "executable": str(cache / (name.replace("-", "_") + "-1243") / "chrome-linux-arm64/chrome"),
                     "urls": ["https://example.invalid/browser.zip"]} for name in supply.BROWSERS]
        def registry_command(command, **kwargs):
            environment = kwargs["env"]
            self.assertEqual(environment["PLAYWRIGHT_HOST_PLATFORM_OVERRIDE"], "ubuntu24.04-arm64")
            self.assertEqual(environment["PLAYWRIGHT_BROWSERS_PATH"], str(cache))
            self.assertNotIn("PLAYWRIGHT_DOWNLOAD_HOST", environment)
            self.assertNotIn("npm_config_playwright_download_host", environment)
            self.assertNotIn("npm_package_config_playwright_skip_browser_download", environment)
            return subprocess.CompletedProcess(command, 0, json.dumps(selected), "")
        overrides = {"PLAYWRIGHT_DOWNLOAD_HOST": "https://unexpected.invalid",
                     "npm_config_playwright_download_host": "https://unexpected.invalid",
                     "npm_package_config_playwright_skip_browser_download": "1"}
        with patch.dict(os.environ, overrides), patch.object(supply.subprocess, "run", side_effect=registry_command):
            result = supply.registry_browsers(self.root / "core", "1.63.0", "linux/arm64", cache)
        self.assertEqual(result[0]["cacheDirectory"], "chromium-1243")
        self.assertEqual(result[0]["executable"], "chrome-linux-arm64/chrome")

    def test_resolver_never_promotes_an_npm_integrity_mismatch(self):
        metadata = {"name": "@playwright/test", "version": "1.63.0", "dist": {
            "tarball": "https://example.invalid/package.tgz",
            "integrity": "sha512-" + base64.b64encode(hashlib.sha512(b"expected").digest()).decode(),
        }}
        with patch.object(supply, "fetch_bytes", side_effect=[json.dumps(metadata).encode(), b"wrong bytes"]):
            with self.assertRaisesRegex(SystemExit, "integrity mismatch"):
                supply.resolve(self.config, self.directory.parents[1], self.root)
        self.assertFalse((self.directory / "playwright-test.tgz").exists())
        self.assertEqual(list(self.root.rglob("*.tmp")), [])

    def test_installer_checks_hash_manifest_elf_platform_without_python(self):
        record = self.fixture()
        install = ROOT / "src/components/playwright"
        script = self.root / "installer/install.sh"
        script.parent.mkdir()
        # Installation remains completely isolated; skip only root ownership
        # changes when this test itself runs as the ordinary bootstrap user.
        script.write_text((install / "install.sh").read_text().replace("chown -R root:root", "true"))
        shutil.copy(install / "validate-install.cjs", script.parent)
        command = ["sh", str(script), "--artifact-root", str(self.root), "--archive-relative", record["archive"]["file"],
                   "--archive-sha256", record["archive"]["sha256"], "--version", record["version"],
                   "--platform", record["platform"], "--destination", str(self.root / "installed")]
        binaries = self.root / "no-python-bin"
        binaries.mkdir()
        for name in ("sh", "dirname", "sha256sum", "cut", "tar", "gzip", "awk", "node", "mktemp", "rm", "cp", "mkdir", "chmod"):
            (binaries / name).symlink_to(shutil.which(name))
        # Fake browser headers exercise installer architecture checks; their
        # external dynamic-linker inspection is the sole mocked native command.
        (binaries / "ldd").write_text('#!/bin/sh\nprintf "libc.so.6 => /lib/libc.so.6\\n"\n')
        (binaries / "ldd").chmod(0o755)
        environment = {**os.environ, "PATH": str(binaries)}
        subprocess.run(command, env=environment, check=True, capture_output=True, text=True)
        self.assertTrue((self.root / "installed/manifest.json").exists())
        for flag, value in [("--archive-sha256", "a" * 64), ("--platform", "linux/arm64"), ("--version", "1.62.1")]:
            wrong = command.copy()
            wrong[wrong.index(flag) + 1] = value
            result = subprocess.run(wrong, env=environment, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
        (binaries / "ldd").write_text('#!/bin/sh\nprintf "libudev.so.1 => not found\\n"\n')
        result = subprocess.run(command, env=environment, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("browser shared libraries", result.stderr)


if __name__ == "__main__":
    unittest.main()
