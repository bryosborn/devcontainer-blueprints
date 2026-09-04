#!/usr/bin/env python3
"""Resolve and cache the non-APK artifacts used by the Wolfi images.

This is an online lock-update helper.  It resolves mutable Microsoft
Marketplace metadata and records the downloaded bytes.  Normal prefetch and
build commands consume the resulting lock and never resolve a version.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Any


PLATFORMS = {
    "linux/amd64": {
        "vscodeClient": "linux-x64",
        "vscodeServer": "server-linux-x64",
        "extension": "linux-x64",
        "kubectl": "amd64",
        "rust": "x86_64-unknown-linux-gnu",
        "toolchain": "linux-x64",
    },
    "linux/arm64": {
        "vscodeClient": "linux-arm64",
        "vscodeServer": "server-linux-arm64",
        "extension": "linux-arm64",
        "kubectl": "arm64",
        "rust": "aarch64-unknown-linux-gnu",
        "toolchain": "linux-arm64",
    },
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config-json", required=True, type=Path)
    parser.add_argument("--config-hash", required=True)
    parser.add_argument("--artifact-root", required=True, type=Path)
    parser.add_argument("--fragment", required=True, type=Path)
    parser.add_argument("--repo-root", required=True, type=Path)
    return parser.parse_args()


def run(command: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, check=True, text=True, **kwargs)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def relative_to_repo(path: Path, repo_root: Path) -> str:
    try:
        return path.resolve().relative_to(repo_root.resolve()).as_posix()
    except ValueError as error:
        raise SystemExit(f"ERROR: artifact is outside the repository: {path}") from error


def fetch_bytes(url: str, *, attempts: int = 5) -> bytes:
    if not url.startswith("https://"):
        raise SystemExit(f"ERROR: refusing non-HTTPS artifact URL: {url}")
    request = urllib.request.Request(
        url, headers={"User-Agent": "devcontainer-blueprints-wolfi/1"}
    )
    last_error: Exception | None = None
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                final_url = response.geturl()
                if not final_url.startswith("https://"):
                    raise SystemExit(
                        f"ERROR: artifact redirected to a non-HTTPS URL: {final_url}"
                    )
                return response.read()
        except (OSError, urllib.error.URLError) as error:
            last_error = error
            if attempt + 1 < attempts:
                time.sleep(min(2 ** attempt, 8))
    raise SystemExit(f"ERROR: failed to download {url}: {last_error}")


def fetch_json(url: str) -> dict[str, Any]:
    try:
        value = json.loads(fetch_bytes(url))
    except json.JSONDecodeError as error:
        raise SystemExit(f"ERROR: endpoint returned invalid JSON: {url}: {error}") from error
    if not isinstance(value, dict):
        raise SystemExit(f"ERROR: endpoint did not return a JSON object: {url}")
    return value


def download_locked(url: str, destination: Path, expected_hash: str = "") -> str:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_file():
        actual = sha256(destination)
        if not expected_hash or actual == expected_hash:
            return actual

    temporary = destination.with_name(f".{destination.name}.{uuid.uuid4().hex}.tmp")
    try:
        temporary.write_bytes(fetch_bytes(url))
        actual = sha256(temporary)
        if expected_hash and actual != expected_hash:
            raise SystemExit(
                f"ERROR: SHA256 mismatch for {url}: expected {expected_hash}, got {actual}"
            )
        os.replace(temporary, destination)
        return actual
    finally:
        temporary.unlink(missing_ok=True)


def resolve_vscode(
    config: dict[str, Any], artifact_root: Path, repo_root: Path, platform: dict[str, str]
) -> tuple[dict[str, Any], dict[str, Any]]:
    vscode = config["vscode"]
    version = vscode["version"]
    quality = vscode["quality"]
    client_platform = platform["vscodeClient"]
    server_platform = platform["vscodeServer"]

    if version == "latest":
        product_metadata_url = (
            f"https://update.code.visualstudio.com/api/update/"
            f"{client_platform}/{quality}/latest"
        )
    else:
        product_metadata_url = (
            f"https://update.code.visualstudio.com/api/versions/"
            f"{version}/{client_platform}/{quality}"
        )
    product_metadata = fetch_json(product_metadata_url)
    commit = product_metadata.get("version")
    product_version = (
        product_metadata.get("productVersion")
        or product_metadata.get("name")
        or version
    )
    if not isinstance(commit, str) or len(commit) != 40 or any(
        character not in "0123456789abcdef" for character in commit.lower()
    ):
        raise SystemExit(f"ERROR: invalid VS Code commit returned for {version}: {commit}")

    server_metadata_url = (
        f"https://update.code.visualstudio.com/api/versions/commit:{commit}/"
        f"{server_platform}/{quality}"
    )
    try:
        server_metadata = fetch_json(server_metadata_url)
    except SystemExit:
        server_metadata = {}
    server_url = server_metadata.get("url") or (
        f"https://update.code.visualstudio.com/commit:{commit}/"
        f"{server_platform}/{quality}"
    )
    upstream_sha256 = server_metadata.get("sha256hash") or ""
    if not isinstance(server_url, str) or not server_url.startswith("https://"):
        raise SystemExit("ERROR: VS Code server resolver returned an unsafe URL")
    if upstream_sha256 and (
        not isinstance(upstream_sha256, str)
        or len(upstream_sha256) != 64
        or any(character not in "0123456789abcdef" for character in upstream_sha256)
    ):
        raise SystemExit("ERROR: VS Code server resolver returned an invalid SHA256")

    archive_name = f"vscode-server-{server_platform.removeprefix('server-')}.tar.gz"
    server_dir = artifact_root / "vscode-server" / quality / commit / server_platform
    archive = server_dir / archive_name
    actual_sha256 = download_locked(server_url, archive, upstream_sha256)
    (server_dir / "SHA256SUMS").write_text(
        f"{actual_sha256}  {archive_name}\n", encoding="utf-8"
    )
    metadata = {
        "productVersion": product_version,
        "commit": commit,
        "quality": quality,
        "clientPlatform": client_platform,
        "serverPlatform": server_platform,
        "url": server_url,
        "archive": relative_to_repo(archive, repo_root),
        "archiveName": archive_name,
        "sha256": actual_sha256,
        "upstreamSha256": upstream_sha256 or None,
        "size": archive.stat().st_size,
        "metadataUrl": server_metadata_url,
        "productMetadataUrl": product_metadata_url,
    }
    server_dir.mkdir(parents=True, exist_ok=True)
    (server_dir / "metadata.json").write_text(
        json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    extension_root = artifact_root / "vscode-extensions"
    extension_source = artifact_root / "resolver-inputs" / "vscode-extensions.txt"
    extension_env = artifact_root / "resolver-inputs" / "vscode-extensions.env"
    extension_source.parent.mkdir(parents=True, exist_ok=True)
    extension_source.write_text(
        "\n".join(vscode["extensions"]) + "\n", encoding="utf-8"
    )
    extension_env.write_text(
        "VSCODE_EXTENSIONS_ARCHIVE_NAME=vscode-extensions.tar.gz\n"
        "VSCODE_EXTENSIONS_CONTAINER_ONLY=true\n"
        "VSCODE_EXTENSIONS_INCLUDE_PRERELEASE=false\n",
        encoding="utf-8",
    )
    run(
        [
            "node",
            str(repo_root / "src/base-vscode/scripts/prefetch-extensions.mjs"),
            "--env-file",
            str(extension_env),
            "--vscode-version",
            str(product_version),
            "--vscode-commit",
            commit,
            "--extensions-file",
            str(extension_source),
            "--target-platform",
            platform["extension"],
            "--artifact-root",
            str(extension_root),
            "--quality",
            quality,
        ],
        cwd=repo_root,
    )

    extension_lock_path = extension_root / "vscode-extensions.lock.json"
    archive_path = extension_root / "vscode-extensions.tar.gz"
    checksum_path = extension_root / "vscode-extensions.tar.gz.sha256"
    extension_lock_source = extension_lock_path.read_text(encoding="utf-8")
    extension_lock = json.loads(extension_lock_source)
    packages = []
    for extension_id, record in sorted(extension_lock["extensions"].items()):
        if record.get("builtin"):
            continue
        vsix_path = repo_root / record["vsixPath"]
        packages.append(
            {
                "id": record["id"],
                "publisher": record["publisher"],
                "name": record["name"],
                "version": record["version"],
                "targetPlatform": record["targetPlatform"],
                "classification": record["classification"],
                "url": record["downloadUrl"],
                "file": relative_to_repo(vsix_path, repo_root),
                "sha256": record["sha256"],
                "size": vsix_path.stat().st_size,
            }
        )
    extensions = {
        "targetVscodeVersion": extension_lock["targetVscodeVersion"],
        "targetVscodeCommit": extension_lock["targetVscodeCommit"],
        "targetPlatform": extension_lock["targetPlatform"],
        "sourceExtensions": extension_lock["sourceExtensions"],
        "containerInstallOrder": extension_lock["containerInstallOrder"],
        "hostOnlyExtensions": extension_lock["hostOnlyExtensions"],
        "builtinDependencies": extension_lock["builtinDependencies"],
        "packages": packages,
        "lockfile": {
            "file": relative_to_repo(extension_lock_path, repo_root),
            "sha256": sha256(extension_lock_path),
        },
        "archive": {
            "file": relative_to_repo(archive_path, repo_root),
            "sha256": sha256(archive_path),
            "size": archive_path.stat().st_size,
            "checksumFile": relative_to_repo(checksum_path, repo_root),
        },
        "warnings": extension_lock.get("warnings", []),
        "payloadLock": extension_lock,
        # Preserve the exact bytes as well as the queryable object. JSON object
        # key order is not semantic, but it is significant to the locked file
        # hash and therefore to deterministic offline archive reconstruction.
        "payloadLockSource": extension_lock_source,
    }
    return metadata, extensions


def resolve_kubectl(
    version: str, artifact_root: Path, repo_root: Path, architecture: str
) -> dict[str, Any]:
    url = f"https://dl.k8s.io/release/v{version}/bin/linux/{architecture}/kubectl"
    checksum_url = f"{url}.sha256"
    published = fetch_bytes(checksum_url).decode("ascii").strip().split()[0]
    if len(published) != 64 or any(
        character not in "0123456789abcdef" for character in published
    ):
        raise SystemExit(f"ERROR: invalid published kubectl checksum: {published}")
    destination = artifact_root / "kubectl" / version / architecture / "kubectl"
    actual = download_locked(url, destination, published)
    destination.chmod(0o755)
    return {
        "version": version,
        "platform": f"linux/{architecture}",
        "url": url,
        "checksumUrl": checksum_url,
        "file": relative_to_repo(destination, repo_root),
        "sha256": actual,
        "size": destination.stat().st_size,
    }


def validate_rust_source(
    source: Path, toolchain: str, components: list[str], target_triple: str
) -> bool:
    metadata_path = source / "metadata.json"
    if not metadata_path.is_file():
        return False
    try:
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False
    return (
        metadata.get("toolchain") == toolchain
        and metadata.get("targetTriple") == target_triple
        and metadata.get("components") == components
        and (source / "rustup-home").is_dir()
        and (source / "cargo-home").is_dir()
    )


def generate_rust_source(
    config: dict[str, Any], repo_root: Path, destination: Path, platform: str
) -> Path:
    rust = config["toolchain"]["rust"]
    with tempfile.TemporaryDirectory(prefix="wolfi-rust-resolver-") as temp_name:
        temporary = Path(temp_name)
        docker_env = temporary / "docker.env"
        toolchain_env = temporary / "toolchain.env"
        docker_env.write_text(
            f"DOCKER_PLATFORM={platform}\n"
            "UPSTREAM_BASE_IMAGE=mcr.microsoft.com/devcontainers/base:3.0-ubuntu22.04\n",
            encoding="utf-8",
        )
        toolchain_env.write_text(
            f"TOOLCHAIN_ARTIFACT_ROOT={destination.as_posix()}\n"
            "TOOLCHAIN_TEST_BASE_IMAGE=${UPSTREAM_BASE_IMAGE}\n"
            f"RUST_TOOLCHAIN={rust['toolchain']}\n"
            f"RUST_COMPONENTS={' '.join(rust['components'])}\n"
            "RUSTUP_HOME=/usr/local/rustup\n"
            "CARGO_HOME=/usr/local/cargo\n"
            "RUSTUP_INIT_VERSION=1.29.1\n"
            "RUSTUP_INIT_SHA256=\n",
            encoding="utf-8",
        )
        environment = os.environ.copy()
        environment["DOCKER_ENV_FILE"] = str(docker_env)
        environment["TOOLCHAIN_ENV_FILE"] = str(toolchain_env)
        subprocess.run(
            [str(repo_root / "src/tool-artifacts/rust/scripts/prefetch.sh")],
            check=True,
            cwd=repo_root,
            env=environment,
        )
    return destination / "rust"


def resolve_rust(
    config: dict[str, Any], artifact_root: Path, repo_root: Path, platform: dict[str, str]
) -> dict[str, Any]:
    rust_config = config["toolchain"]["rust"]
    toolchain = rust_config["toolchain"]
    components = rust_config["components"]
    target_triple = platform["rust"]
    destination_dir = artifact_root / "rust" / toolchain / target_triple
    archive = destination_dir / "rust-toolchain.tar.gz"
    metadata_path = destination_dir / "metadata.json"

    cached_metadata: dict[str, Any] | None = None
    if archive.is_file() and metadata_path.is_file():
        try:
            candidate = json.loads(metadata_path.read_text(encoding="utf-8"))
            if (
                candidate.get("toolchain") == toolchain
                and candidate.get("components") == components
                and candidate.get("targetTriple") == target_triple
                and candidate.get("sha256") == sha256(archive)
            ):
                cached_metadata = candidate
        except (OSError, json.JSONDecodeError):
            cached_metadata = None
    if cached_metadata is not None:
        cached_metadata["file"] = relative_to_repo(archive, repo_root)
        return cached_metadata

    existing = repo_root / "artifacts/toolchain/rust"
    if validate_rust_source(existing, toolchain, components, target_triple):
        source = existing
    else:
        generated_root = artifact_root / "resolver-rust-source"
        shutil.rmtree(generated_root, ignore_errors=True)
        source = generate_rust_source(config, repo_root, generated_root, config["images"]["platform"])
        if not validate_rust_source(source, toolchain, components, target_triple):
            raise SystemExit("ERROR: generated Rust artifact tree did not match the request")

    destination_dir.mkdir(parents=True, exist_ok=True)
    temporary_archive = destination_dir / ".rust-toolchain.tar.gz.tmp"
    with temporary_archive.open("wb") as output:
        tar_process = subprocess.Popen(
            [
                "tar",
                "--sort=name",
                "--mtime=UTC 1970-01-01",
                "--owner=0",
                "--group=0",
                "--numeric-owner",
                "-cf",
                "-",
                "-C",
                str(source),
                "rustup-home",
                "cargo-home",
            ],
            stdout=subprocess.PIPE,
        )
        assert tar_process.stdout is not None
        gzip_process = subprocess.run(
            ["gzip", "-n", "-6"], stdin=tar_process.stdout, stdout=output, check=True
        )
        del gzip_process
        tar_process.stdout.close()
        if tar_process.wait() != 0:
            raise SystemExit("ERROR: failed to package the Rust artifact tree")
    os.replace(temporary_archive, archive)

    rustup_init_version = "1.29.1"
    rustup_url = (
        "https://static.rust-lang.org/rustup/archive/"
        f"{rustup_init_version}/{target_triple}/rustup-init"
    )
    published_checksum = (
        fetch_bytes(f"{rustup_url}.sha256").decode("ascii").strip().split()[0]
    )
    metadata = {
        "toolchain": toolchain,
        "components": components,
        "targetTriple": target_triple,
        "file": relative_to_repo(archive, repo_root),
        "sha256": sha256(archive),
        "size": archive.stat().st_size,
        "rustupInit": {
            "version": rustup_init_version,
            "url": rustup_url,
            "checksumUrl": f"{rustup_url}.sha256",
            "sha256": published_checksum,
        },
    }
    metadata_path.write_text(
        json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return metadata


def main() -> None:
    args = parse_args()
    repo_root = args.repo_root.resolve()
    artifact_root = args.artifact_root.resolve()
    artifact_root.mkdir(parents=True, exist_ok=True)
    try:
        config = json.loads(args.config_json.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"ERROR: cannot read normalized config: {error}") from error
    platform_name = config["images"]["platform"]
    if platform_name not in PLATFORMS:
        raise SystemExit(f"ERROR: unsupported target platform: {platform_name}")
    platform = PLATFORMS[platform_name]

    vscode, extensions = resolve_vscode(config, artifact_root, repo_root, platform)
    resolved: dict[str, Any] = {
        "vscode": vscode,
        "extensions": extensions,
    }
    if "kubectl" in config["toolchain"]:
        resolved["kubectl"] = resolve_kubectl(
            config["toolchain"]["kubectl"],
            artifact_root,
            repo_root,
            platform["kubectl"],
        )
    if "rust" in config["toolchain"]:
        resolved["rust"] = resolve_rust(config, artifact_root, repo_root, platform)

    fragment = {
        "schemaVersion": 1,
        "name": "wolfi-vendor-artifacts",
        "version": "1",
        "configSemanticSha256": args.config_hash,
        "resolved": resolved,
    }
    args.fragment.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.fragment.with_name(f".{args.fragment.name}.{uuid.uuid4().hex}.tmp")
    temporary.write_text(
        json.dumps(fragment, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    os.replace(temporary, args.fragment)
    print(f"Resolved Wolfi vendor artifacts into {artifact_root}")


if __name__ == "__main__":
    main()
