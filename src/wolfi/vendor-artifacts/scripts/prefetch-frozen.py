#!/usr/bin/env python3
"""Fetch or verify only the exact vendor artifacts recorded in the Wolfi lock."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", required=True, type=Path)
    parser.add_argument("--repo-root", required=True, type=Path)
    parser.add_argument("--offline", action="store_true", help="Verify cached bytes without downloading missing artifacts")
    return parser.parse_args()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def checked_path(repo_root: Path, value: object, label: str) -> Path:
    if not isinstance(value, str) or not value or Path(value).is_absolute():
        raise SystemExit(f"ERROR: {label} must be a repository-relative path")
    path = (repo_root / value).resolve()
    try:
        path.relative_to(repo_root.resolve())
    except ValueError as error:
        raise SystemExit(f"ERROR: {label} escapes the repository: {value}") from error
    return path


def validate_hash(value: object, label: str) -> str:
    if (
        not isinstance(value, str)
        or len(value) != 64
        or any(character not in "0123456789abcdef" for character in value)
    ):
        raise SystemExit(f"ERROR: {label} is not a lowercase SHA256")
    return value


def fetch(url: object, destination: Path, expected: str, *, offline: bool = False) -> None:
    if not isinstance(url, str) or not url.startswith("https://"):
        raise SystemExit(f"ERROR: refusing non-HTTPS locked URL: {url}")
    if destination.is_file() and sha256(destination) == expected:
        return
    if offline:
        if destination.is_file():
            raise SystemExit(
                f"ERROR: SHA256 mismatch for offline artifact {destination}: "
                f"expected {expected}, got {sha256(destination)}"
            )
        raise SystemExit(
            f"ERROR: offline vendor artifact is missing: {destination}\n"
            "Run frozen prefetch on a connected machine and preserve its artifact bundle."
        )
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(f".{destination.name}.{uuid.uuid4().hex}.tmp")
    request = urllib.request.Request(
        url, headers={"User-Agent": "devcontainer-blueprints-wolfi/1"}
    )
    last_error: Exception | None = None
    try:
        for attempt in range(5):
            try:
                with urllib.request.urlopen(request, timeout=120) as response:
                    final_url = response.geturl()
                    if not final_url.startswith("https://"):
                        raise SystemExit(
                            f"ERROR: locked artifact redirected to non-HTTPS: {final_url}"
                        )
                    with temporary.open("wb") as output:
                        while chunk := response.read(1024 * 1024):
                            output.write(chunk)
                actual = sha256(temporary)
                if actual != expected:
                    raise SystemExit(
                        f"ERROR: SHA256 mismatch for {url}: expected {expected}, got {actual}"
                    )
                os.replace(temporary, destination)
                return
            except (OSError, urllib.error.URLError) as error:
                last_error = error
                if attempt + 1 < 5:
                    time.sleep(min(2 ** attempt, 8))
        raise SystemExit(f"ERROR: failed to download {url}: {last_error}")
    finally:
        temporary.unlink(missing_ok=True)


def verify_local(path: Path, expected: str, label: str) -> None:
    if not path.is_file():
        raise SystemExit(
            f"ERROR: frozen {label} is missing: {path}\n"
            "It is generated only by ./scripts/wolfi/update-lock.sh and must be "
            "preserved in the artifact bundle."
        )
    actual = sha256(path)
    if actual != expected:
        raise SystemExit(
            f"ERROR: SHA256 mismatch for {label}: expected {expected}, got {actual}"
        )


def main() -> None:
    args = parse_args()
    repo_root = args.repo_root.resolve()
    try:
        lock = json.loads(args.lock.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"ERROR: cannot read Wolfi lock: {error}") from error
    resolved = lock.get("resolved", {})

    server = resolved.get("vscode")
    if server is not None:
        server_path = checked_path(repo_root, server.get("archive"), "VS Code archive")
        fetch(server.get("url"), server_path, validate_hash(server.get("sha256"), "VS Code SHA256"), offline=args.offline)
        (server_path.parent / "SHA256SUMS").write_text(
            f"{server['sha256']}  {server_path.name}\n", encoding="utf-8"
        )

    kubectl = resolved.get("kubectl")
    if kubectl is not None:
        if not isinstance(kubectl, dict):
            raise SystemExit("ERROR: resolved.kubectl must be an object")
        kubectl_path = checked_path(repo_root, kubectl.get("file"), "kubectl artifact")
        fetch(
            kubectl.get("url"),
            kubectl_path,
            validate_hash(kubectl.get("sha256"), "kubectl SHA256"),
            offline=args.offline,
        )
        kubectl_path.chmod(0o755)

    extensions = resolved.get("extensions")
    if extensions is not None:
        for index, package in enumerate(extensions.get("packages", [])):
            package_path = checked_path(
                repo_root, package.get("file"), f"extension package {index}"
            )
            fetch(
                package.get("url"),
                package_path,
                validate_hash(package.get("sha256"), f"extension package {index} SHA256"),
                offline=args.offline,
            )

        lock_record = extensions.get("lockfile", {})
        extension_lock_path = checked_path(
            repo_root, lock_record.get("file"), "extension payload lock"
        )
        payload_lock = extensions.get("payloadLock")
        if not isinstance(payload_lock, dict):
            raise SystemExit("ERROR: global lock does not embed the extension payload lock")
        payload_lock_source = extensions.get("payloadLockSource")
        if not isinstance(payload_lock_source, str) or not payload_lock_source:
            raise SystemExit("ERROR: global lock does not preserve extension lock bytes")
        try:
            parsed_payload_lock = json.loads(payload_lock_source)
        except json.JSONDecodeError as error:
            raise SystemExit(
                f"ERROR: embedded extension lock source is invalid JSON: {error}"
            ) from error
        if parsed_payload_lock != payload_lock:
            raise SystemExit(
                "ERROR: embedded extension lock source differs from its parsed metadata"
            )
        expected_payload_lock = payload_lock_source.encode("utf-8")
        expected_lock_hash = validate_hash(
            lock_record.get("sha256"), "extension payload lock SHA256"
        )
        if hashlib.sha256(expected_payload_lock).hexdigest() != expected_lock_hash:
            raise SystemExit("ERROR: embedded extension lock does not match its locked hash")
        if not extension_lock_path.is_file() or sha256(extension_lock_path) != expected_lock_hash:
            extension_lock_path.parent.mkdir(parents=True, exist_ok=True)
            extension_lock_path.write_bytes(expected_payload_lock)

        archive_record = extensions.get("archive", {})
        archive_path = checked_path(repo_root, archive_record.get("file"), "extension archive")
        expected_archive_hash = validate_hash(
            archive_record.get("sha256"), "extension archive SHA256"
        )
        if not archive_path.is_file() or sha256(archive_path) != expected_archive_hash:
            subprocess.run(
                [
                    str(repo_root / "src/wolfi/components/vscode/package-extensions.sh"),
                    "--lock",
                    str(extension_lock_path),
                    "--output",
                    str(archive_path),
                ],
                check=True,
                cwd=repo_root,
            )
        verify_local(archive_path, expected_archive_hash, "extension archive")

    rust = resolved.get("rust")
    if rust is not None:
        if not isinstance(rust, dict):
            raise SystemExit("ERROR: resolved.rust must be an object")
        rust_path = checked_path(repo_root, rust.get("file"), "Rust archive")
        verify_local(
            rust_path,
            validate_hash(rust.get("sha256"), "Rust SHA256"),
            "Rust archive",
        )

    print("Verified all frozen Wolfi vendor artifacts.")


if __name__ == "__main__":
    main()
