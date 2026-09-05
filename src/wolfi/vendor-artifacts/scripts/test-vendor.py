#!/usr/bin/env python3
"""Network-free regression tests for optional vendor inputs and Rust isolation."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[4]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


resolver = load("wolfi_vendor_resolver", "resolve-vendor.py")
frozen = load("wolfi_vendor_frozen", "prefetch-frozen.py")


class VendorTests(unittest.TestCase):
    def test_rust_install_does_not_require_unselected_rustfmt_or_clippy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cargo_bin = root / "payload/cargo-home/bin"
            cargo_bin.mkdir(parents=True)
            (root / "payload/rustup-home").mkdir()
            tools = {
                "rustup": '#!/bin/sh\ncase "$1" in show) echo nightly-2026-04-11-x86_64-unknown-linux-gnu;; component) echo rust-src;; esac\n',
                "rustc": '#!/bin/sh\necho rustc-fixture\n',
                "cargo": '#!/bin/sh\n[ "$1" = --version ] || exit 99\necho cargo-fixture\n',
            }
            for name, body in tools.items():
                binary = cargo_bin / name
                binary.write_text(body)
                binary.chmod(0o755)
            archive = root / "rust.tar.gz"
            with tarfile.open(archive, "w:gz") as payload:
                for name in ("rustup-home", "cargo-home"):
                    payload.add(root / "payload" / name, arcname=name)
            script = root / "install-rust.sh"
            # Redirect installation to a disposable prefix; all actual archive
            # validation and selected-component execution stays unchanged.
            source = (ROOT / "src/wolfi/components/rust/install.sh").read_text()
            source = source.replace("/usr/local", str(root / "installed"))
            source = source.replace("chown -R root:root", "true")
            script.write_text(source)
            no_python_bin = root / "no-python-bin"
            no_python_bin.mkdir()
            for command in ("sh", "sha256sum", "cut", "tar", "gzip", "awk", "grep", "mktemp", "rm", "mkdir", "cp", "find", "chmod"):
                (no_python_bin / command).symlink_to(shutil.which(command))
            for environment in (os.environ, {**os.environ, "PATH": str(no_python_bin)}):
                for components in ("rust-src", ""):
                    subprocess.run(["sh", str(script), "--artifact-root", str(root),
                                    "--archive-relative", archive.name,
                                    "--archive-sha256", hashlib.sha256(archive.read_bytes()).hexdigest(),
                                    "--toolchain", "nightly-2026-04-11", "--target-triple", "x86_64-unknown-linux-gnu",
                                    "--components", components], env=environment, check=True, capture_output=True, text=True)

    def test_empty_selection_does_not_resolve_or_fetch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "config.json"
            config.write_text(json.dumps({"image": {"platform": "linux/amd64"}, "build": {}, "utilities": {}}))
            fragment = root / "fragment.json"
            args = type("Args", (), dict(repo_root=root, artifact_root=root / "vendor", config_json=config,
                                          config_hash="a" * 64, fragment=fragment, base_image=None))()
            with patch.object(resolver, "parse_args", return_value=args), \
                    patch.object(resolver, "fetch_bytes", side_effect=AssertionError("network used")):
                resolver.main()
            self.assertEqual(json.loads(fragment.read_text())["resolved"], {})
            lock = root / "lock.json"
            lock.write_text(json.dumps({"schemaVersion": 2, "resolved": {}}))
            args = type("Args", (), dict(repo_root=root, lock=lock, offline=True))()
            with patch.object(frozen, "parse_args", return_value=args), \
                    patch.object(frozen, "fetch", side_effect=AssertionError("network used")):
                frozen.main()

    def test_offline_vendor_fetch_never_downloads_missing_or_corrupt_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = b"locked vendor bytes"
            digest = hashlib.sha256(payload).hexdigest()
            fixtures = [
                {"vscode": {"archive": "payload", "url": "https://example.invalid/server", "sha256": digest}},
                {"kubectl": {"file": "payload", "url": "https://example.invalid/kubectl", "sha256": digest}},
                {"extensions": {"packages": [{"file": "payload", "url": "https://example.invalid/extension", "sha256": digest}]}},
            ]
            lock = root / "lock.json"
            args = type("Args", (), dict(repo_root=root, lock=lock, offline=True))()
            for fixture in fixtures:
                lock.write_text(json.dumps({"resolved": fixture}))
                for content, message in ((None, "offline vendor artifact is missing"), (b"corrupt", "SHA256 mismatch")):
                    with self.subTest(fixture=next(iter(fixture)), content=content):
                        (root / "payload").unlink(missing_ok=True)
                        if content is not None:
                            (root / "payload").write_bytes(content)
                        with patch.object(frozen, "parse_args", return_value=args), \
                                patch.object(frozen.urllib.request, "build_opener", side_effect=AssertionError("network used")), \
                                self.assertRaisesRegex(SystemExit, message):
                            frozen.main()
            (root / "payload").write_bytes(payload)
            with patch.object(frozen.urllib.request, "build_opener", side_effect=AssertionError("network used")):
                frozen.fetch("https://example.invalid/payload", root / "payload", digest, offline=True)

    def test_offline_prefetch_can_restore_exact_embedded_extension_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "archive.tar.gz"
            archive.write_bytes(b"verified archive")
            source = '{"packages": []}\n'
            lock = root / "lock.json"
            lock.write_text(json.dumps({"resolved": {"extensions": {
                "packages": [], "payloadLock": json.loads(source), "payloadLockSource": source,
                "lockfile": {"file": "extensions.lock.json", "sha256": hashlib.sha256(source.encode()).hexdigest()},
                "archive": {"file": archive.name, "sha256": hashlib.sha256(archive.read_bytes()).hexdigest()},
            }}}))
            args = type("Args", (), dict(repo_root=root, lock=lock, offline=True))()
            with patch.object(frozen, "parse_args", return_value=args), \
                    patch.object(frozen.urllib.request, "build_opener", side_effect=AssertionError("network used")):
                frozen.main()
            self.assertEqual((root / "extensions.lock.json").read_bytes(), source.encode())

    def test_rust_packaging_removes_only_its_staging_tree_and_cache_stays_usable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifacts = root / "vendor"
            artifacts.mkdir()
            unrelated = artifacts / "unrelated-source"
            unrelated.mkdir()
            (unrelated / "keep").write_text("preserve")
            config = {"image": {"platform": "linux/amd64"}, "build": {"rust": {
                "toolchain": "nightly-2026-04-11", "components": ["rust-src"],
            }}}
            init_payload = b"rustup-init fixture"
            init_hash = hashlib.sha256(init_payload).hexdigest()
            def download(url, path, expected):
                self.assertEqual(expected, init_hash)
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(init_payload)
            def generate(config, repo_root, destination, base_image, rustup_init, rustup_hash):
                for name in ("rustup-home", "cargo-home"):
                    (destination / name).mkdir(parents=True)
                    (destination / name / "fixture").write_text(name)
                (destination / "metadata.json").write_text(json.dumps({
                    **config["build"]["rust"], "targetTriple": "x86_64-unknown-linux-gnu",
                }))
                return destination
            with patch.object(resolver, "fetch_bytes", return_value=init_hash.encode()), \
                    patch.object(resolver, "download_locked", side_effect=download), \
                    patch.object(resolver, "generate_rust_source", side_effect=generate):
                resolved = resolver.resolve_rust(config, artifacts, root, resolver.PLATFORMS["linux/amd64"], "base@sha256:" + "a" * 64)
            self.assertFalse((artifacts / "resolver-rust-source").exists())
            self.assertEqual((unrelated / "keep").read_text(), "preserve")
            with patch.object(resolver, "fetch_bytes", side_effect=AssertionError("network used")), \
                    patch.object(resolver, "generate_rust_source", side_effect=AssertionError("cache was not reused")):
                self.assertEqual(resolver.resolve_rust(config, artifacts, root, resolver.PLATFORMS["linux/amd64"], None), resolved)
            lock = root / "lock.json"
            lock.write_text(json.dumps({"resolved": {"rust": resolved}}))
            args = type("Args", (), dict(repo_root=root, lock=lock, offline=True))()
            with patch.object(frozen, "parse_args", return_value=args), \
                    patch.object(frozen.urllib.request, "build_opener", side_effect=AssertionError("network used")):
                frozen.main()

    def test_vscode_without_extensions_only_downloads_server(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = b"server archive fixture"
            digest = hashlib.sha256(payload).hexdigest()
            def download(url, path, expected):
                self.assertEqual(expected, digest)
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(payload)
                return digest
            metadata = [{"version": "a" * 40, "productVersion": "1.100.0"},
                        {"url": "https://example.invalid/server", "sha256hash": digest}]
            with patch.object(resolver, "fetch_json", side_effect=metadata), \
                    patch.object(resolver, "download_locked", side_effect=download), \
                    patch.object(resolver, "run", side_effect=AssertionError("extension resolver invoked")):
                server, extensions = resolver.resolve_vscode(
                    {"vscode": {"version": "1.100.0", "quality": "stable", "extensions": []}},
                    root / "vendor", root, resolver.PLATFORMS["linux/amd64"])
            self.assertIsNone(extensions)
            self.assertEqual(server["sha256"], digest)
            self.assertFalse((root / "vendor/vscode-extensions").exists())

    def test_foreign_rust_initializer_runs_only_in_pinned_wolfi_build(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            log = root / "docker.log"
            init = root / "foreign-rustup-init"
            init.write_text("#!/bin/sh\necho 'foreign initializer executed on host' >&2\nexit 97\n")
            init.chmod(0o755)
            (fake_bin / "uname").write_text("#!/bin/sh\ncase \"$1\" in -m) echo aarch64;; -s) echo Linux;; esac\n")
            (fake_bin / "docker").write_text("""#!/usr/bin/env python3
import json,os,sys,pathlib
args=sys.argv[1:]
with open(os.environ['WOLFI_TEST_DOCKER_LOG'],'a') as log: log.write(json.dumps(args)+'\\n')
if args[0]=='create': print('fixture-container')
if args[0]=='cp':
    for name in ('rustup-home','cargo-home'): (pathlib.Path(args[-1])/name).mkdir(parents=True)
if args[0]=='build':
    assert 'BASE_IMAGE=cgr.dev/chainguard/wolfi-base@sha256:'+'a'*64 in args
    assert 'linux/amd64' in args
    assert 'FROM ${BASE_IMAGE}' in (pathlib.Path(args[-1])/'Dockerfile').read_text()
""")
            for script in fake_bin.iterdir():
                script.chmod(0o755)
            environment = dict(os.environ, PATH=f"{fake_bin}:{os.environ['PATH']}", WOLFI_TEST_DOCKER_LOG=str(log))
            for components in ("rust-analyzer", ""):
                subprocess.run([str(ROOT / "src/wolfi/components/rust/prefetch.sh"),
                                "--artifact-root", str(root / "output"), "--platform", "linux/amd64",
                                "--base-image", "cgr.dev/chainguard/wolfi-base@sha256:" + "a" * 64,
                                "--toolchain", "nightly-2026-04-11", "--components", components,
                                "--rustup-init", str(init), "--rustup-init-sha256", hashlib.sha256(init.read_bytes()).hexdigest(),
                                "--rustup-init-version", "1.29.1"], env=environment, check=True, capture_output=True, text=True)
                metadata = json.loads((root / "output/metadata.json").read_text())
                self.assertEqual(metadata["targetTriple"], "x86_64-unknown-linux-gnu")
                self.assertEqual(metadata["components"], components.split())
            commands = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertEqual([c[0] for c in commands], ["build", "create", "cp", "rm", "image"] * 2)
            self.assertIn("RUST_COMPONENTS=", commands[5])


if __name__ == "__main__":
    unittest.main()
