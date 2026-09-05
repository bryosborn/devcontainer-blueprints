#!/usr/bin/env python3
"""Resolve and cache signed Wolfi APK closures from immutable input metadata."""

from __future__ import annotations

import argparse
import re
import shlex
import shutil
import tempfile
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

from supply_lib import (
    SupplyError,
    canonical_json_sha256,
    download,
    ensure_empty_directory,
    exact_version_matches,
    expand_package_roots,
    index_signature_key_names,
    load_json,
    load_package_mapping,
    parse_apkindex,
    parse_pkginfo,
    require_oci_digest,
    require_platform,
    require_relative_path,
    require_sha256,
    roots_for_modules,
    run,
    sha256_file,
    validate_https_repository,
    validate_pinned_image,
    write_json_atomic,
)


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_PACKAGE_MAP = SCRIPT_DIR.parent / "package-roots.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Resolve configured Wolfi package sets against downloaded, "
            "signature-verified indexes and emit an update-lock fragment."
        )
    )
    parser.add_argument("--config-json", required=True, type=Path)
    parser.add_argument("--config-sha256", required=True)
    parser.add_argument("--base-image", required=True)
    parser.add_argument("--base-digest", required=True)
    parser.add_argument("--base-image-metadata", required=True, type=Path)
    parser.add_argument("--platform", required=True)
    parser.add_argument("--main-repository", required=True)
    parser.add_argument("--extra-repository", required=True)
    parser.add_argument("--package-map", type=Path, default=DEFAULT_PACKAGE_MAP)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument(
        "--artifact-directory",
        required=True,
        help="Platform-qualified, repository-relative APK artifact path for the lock.",
    )
    parser.add_argument("--fragment", required=True, type=Path)
    parser.add_argument(
        "--package-set",
        action="append",
        dest="package_sets",
        help="Resolve only this package set (repeatable); default resolves every set.",
    )
    return parser.parse_args()


def require_config(args: argparse.Namespace) -> dict[str, Any]:
    config = load_json(args.config_json, "normalized Wolfi configuration")
    if not isinstance(config, dict):
        raise SupplyError("normalized Wolfi configuration must be a JSON object")
    expected_hash = require_sha256(args.config_sha256, "config SHA256")
    actual_hash = canonical_json_sha256(config)
    if actual_hash != expected_hash:
        raise SupplyError(
            f"normalized config SHA256 mismatch: expected {expected_hash}, got {actual_hash}"
        )
    configured_platform = config.get("image", {}).get("platform")
    if configured_platform != args.platform:
        raise SupplyError(
            f"config platform {configured_platform!r} does not match {args.platform!r}"
        )
    repositories = config.get("wolfi", {}).get("repositories", {})
    if repositories.get("main") != args.main_repository:
        raise SupplyError("explicit main repository does not match normalized config")
    if repositories.get("extra") != args.extra_repository:
        raise SupplyError("explicit extra repository does not match normalized config")
    return config


def require_base_metadata(
    path: Path,
    *,
    pinned_image: str,
    digest: str,
    platform: str,
) -> dict[str, Any]:
    metadata = load_json(path, "base-image artifact metadata")
    required = {
        "schemaVersion",
        "platform",
        "pinnedReference",
        "digest",
        "localReference",
        "artifactDirectory",
        "file",
        "sha256",
        "size",
    }
    if not isinstance(metadata, dict) or set(metadata) != required:
        raise SupplyError("base-image artifact metadata has unexpected fields")
    if metadata["schemaVersion"] != 1:
        raise SupplyError("base-image artifact metadata schemaVersion must be 1")
    if metadata["platform"] != platform:
        raise SupplyError("base-image artifact metadata platform mismatch")
    if metadata["pinnedReference"] != pinned_image or metadata["digest"] != digest:
        raise SupplyError("base-image artifact metadata pin mismatch")
    require_relative_path(metadata["artifactDirectory"], "base artifact directory")
    require_relative_path(metadata["file"], "base artifact file")
    require_sha256(metadata["sha256"], "base artifact SHA256")
    if not isinstance(metadata["size"], int) or metadata["size"] <= 0:
        raise SupplyError("base artifact size must be a positive integer")
    return metadata


def extract_base_keys(base_image: str, platform: str, destination: Path) -> None:
    container_name = f"wolfi-apk-keys-{uuid.uuid4().hex[:12]}"
    destination.mkdir(parents=True, exist_ok=True)
    try:
        run(
            [
                "docker",
                "create",
                "--name",
                container_name,
                "--platform",
                platform,
                "--entrypoint",
                "/bin/true",
                base_image,
            ],
            capture_output=True,
        )
        run(
            ["docker", "cp", f"{container_name}:/etc/apk/keys/.", str(destination)],
            capture_output=True,
        )
    finally:
        run(
            ["docker", "rm", "--force", container_name],
            check=False,
            capture_output=True,
        )


def fetch_verified_index(
    *,
    base_image: str,
    platform: str,
    repository_url: str,
    destination: Path,
) -> str:
    container_name = f"wolfi-apk-index-{uuid.uuid4().hex[:12]}"
    with tempfile.TemporaryDirectory(prefix="wolfi-apk-index-") as temporary_name:
        workspace = Path(temporary_name)
        quoted_repository = shlex.quote(repository_url)
        command = (
            "set -eu; mkdir -p /work/cache; "
            f"printf '%s\\n' {quoted_repository} > /work/repositories.list; "
            "apk --cache-dir /work/cache --repositories-file /work/repositories.list "
            "update >/work/apk-update.log 2>&1"
        )
        result = None
        try:
            run(
                [
                    "docker",
                    "create",
                    "--name",
                    container_name,
                    "--platform",
                    platform,
                    "--entrypoint",
                    "/bin/sh",
                    base_image,
                    "-c",
                    command,
                ],
                capture_output=True,
            )
            result = run(
                ["docker", "start", "--attach", container_name],
                check=False,
                capture_output=True,
            )
            run(
                ["docker", "cp", f"{container_name}:/work/.", str(workspace)],
                capture_output=True,
            )
        finally:
            run(
                ["docker", "rm", "--force", container_name],
                check=False,
                capture_output=True,
            )
        if result is None or result.returncode != 0:
            log_path = workspace / "apk-update.log"
            detail = log_path.read_text(encoding="utf-8") if log_path.is_file() else ""
            raise SupplyError(f"signed APK index fetch failed: {detail.strip()}")
        indexes = sorted((workspace / "cache").glob("APKINDEX.*.tar.gz"))
        if len(indexes) != 1:
            raise SupplyError(
                f"expected one cached index for {repository_url}, found {len(indexes)}"
            )
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(indexes[0], destination)
        return indexes[0].name


def prepare_indexes_and_keys(
    output_dir: Path,
    repositories: dict[str, str],
    architecture: str,
    base_image: str,
    platform: str,
) -> tuple[dict[str, dict[str, Any]], list[dict[str, Any]]]:
    index_key_names: dict[str, list[str]] = {}
    repository_records: dict[str, dict[str, Any]] = {}

    for name, repository_url in repositories.items():
        relative_index = (
            Path("repositories") / name / architecture / "APKINDEX.tar.gz"
        )
        index_path = output_dir / relative_index
        index_url = f"{repository_url}/{architecture}/APKINDEX.tar.gz"
        cache_file_name = fetch_verified_index(
            base_image=base_image,
            platform=platform,
            repository_url=repository_url,
            destination=index_path,
        )
        index_hash = sha256_file(index_path)
        key_names = index_signature_key_names(index_path)
        index_key_names[name] = key_names
        repository_records[name] = {
            "url": repository_url,
            "architecture": architecture,
            "indexUrl": index_url,
            "indexFile": relative_index.as_posix(),
            "indexSha256": index_hash,
            "indexSize": index_path.stat().st_size,
            "cacheFileName": cache_file_name,
            "signatureKeyNames": key_names,
        }

    with tempfile.TemporaryDirectory(prefix="wolfi-base-keys-") as temporary_name:
        extracted = Path(temporary_name)
        extract_base_keys(base_image, platform, extracted)
        advertised_keys = sorted(
            {key_name for names in index_key_names.values() for key_name in names}
        )
        keys_directory = output_dir / "keys"
        keys_directory.mkdir(parents=True, exist_ok=True)
        key_records: list[dict[str, Any]] = []
        for key_name in advertised_keys:
            if Path(key_name).name != key_name:
                raise SupplyError(f"unsafe APK signing-key name: {key_name}")
            source = extracted / key_name
            if not source.is_file():
                continue
            destination = keys_directory / key_name
            shutil.copyfile(source, destination)
            fingerprint = sha256_file(destination)
            key_records.append(
                {
                    "name": key_name,
                    "file": destination.relative_to(output_dir).as_posix(),
                    "sha256": fingerprint,
                    "fingerprintSha256": fingerprint,
                    "size": destination.stat().st_size,
                }
            )

    fingerprint_by_name = {
        record["name"]: record["fingerprintSha256"] for record in key_records
    }
    for name, record in repository_records.items():
        trusted_names = [
            key_name
            for key_name in index_key_names[name]
            if key_name in fingerprint_by_name
        ]
        if not trusted_names:
            raise SupplyError(
                f"digest-pinned base image has none of the signing keys advertised "
                f"by the {name} index"
            )
        record["trustedSignatureKeyNames"] = trusted_names
        record["signatureKeyFingerprintsSha256"] = [
            fingerprint_by_name[key_name] for key_name in trusted_names
        ]

    return repository_records, key_records


def resolve_package_set_urls(
    *,
    base_image: str,
    platform: str,
    architecture: str,
    artifact_dir: Path,
    repositories: dict[str, str],
    repository_records: dict[str, dict[str, Any]],
    roots: list[dict[str, Any]],
    package_sets: dict[str, list[str]],
) -> dict[str, list[tuple[str, str]]]:
    catalog: dict[tuple[str, str], tuple[str, str]] = {}
    ambiguous: set[tuple[str, str]] = set()
    for repository in ("main", "extra"):
        index_path = artifact_dir / repository_records[repository]["indexFile"]
        for package in parse_apkindex(index_path):
            identity = (package["name"], package["version"])
            target = (repository, f"{package['name']}-{package['version']}.apk")
            previous = catalog.get(identity)
            if previous is not None and previous != target:
                ambiguous.add(identity)
            else:
                catalog[identity] = target

    with tempfile.TemporaryDirectory(prefix="wolfi-apk-offline-resolve-") as temp_name:
        workspace = Path(temp_name)
        commands = [
            "set -eu",
            (
                "mkdir -p /work/set-plans /work/root/etc/apk "
                "/work/root/lib/apk/db /work/root/var/cache/apk /work/root/dev"
            ),
            "cp -R /artifacts/repositories /artifacts/keys /work/root/",
            "cp /etc/apk/world /work/root/etc/apk/world",
            (
                "printf '%s\\n' "
                "file:///work/root/repositories/main "
                "file:///work/root/repositories/extra "
                "> /work/repositories.list"
            ),
            (
                "touch /work/root/lib/apk/db/installed "
                "/work/root/lib/apk/db/scripts.tar /work/root/lib/apk/db/triggers "
                "/work/root/dev/null"
            ),
        ]
        for set_name, modules in sorted(package_sets.items()):
            selected_roots = roots_for_modules(roots, modules)
            if not selected_roots:
                continue
            packages = " ".join(shlex.quote(root["name"]) for root in selected_roots)
            commands.append(
                "apk --root /work/root --no-network --keys-dir /work/root/keys "
                "--repositories-file /work/repositories.list "
                "add --initdb --simulate "
                f"{packages} > /work/set-plans/{shlex.quote(set_name)}.txt "
                f"2>/work/set-plans/{shlex.quote(set_name)}.log"
            )
        script = "; ".join(commands)
        container_name = f"wolfi-apk-resolve-{uuid.uuid4().hex[:12]}"
        result = None
        try:
            run(
                [
                    "docker",
                    "create",
                    "--name",
                    container_name,
                    "--network",
                    "none",
                    "--platform",
                    platform,
                    "--entrypoint",
                    "/bin/sh",
                    base_image,
                    "-c",
                    script,
                ],
                capture_output=True,
            )
            run(
                [
                    "docker",
                    "cp",
                    f"{artifact_dir.resolve()}/.",
                    f"{container_name}:/artifacts",
                ],
                capture_output=True,
            )
            result = run(
                ["docker", "start", "--attach", container_name],
                check=False,
                capture_output=True,
            )
            run(
                ["docker", "cp", f"{container_name}:/work/.", str(workspace)],
                capture_output=True,
            )
        finally:
            run(
                ["docker", "rm", "--force", container_name],
                check=False,
                capture_output=True,
            )

        output_directory = workspace / "set-plans"
        if result is None or result.returncode != 0:
            details: list[str] = []
            for log_path in sorted(output_directory.glob("*.log")):
                details.append(
                    f"[{log_path.name}]\n{log_path.read_text(encoding='utf-8')}"
                )
            detail = "\n".join(details).strip()
            raise SupplyError(
                "offline, signature-checked APK resolution failed"
                f"{f': {detail}' if detail else ''}"
            )

        resolved: dict[str, list[tuple[str, str]]] = {}
        install_line = re.compile(
            r"^\(\d+/\d+\) Installing ([A-Za-z0-9][A-Za-z0-9+_.@~-]*) "
            r"\(([^()]+)\)$"
        )
        for set_name in sorted(package_sets):
            plan_path = output_directory / f"{set_name}.txt"
            if not plan_path.is_file():
                continue
            entries: set[tuple[str, str]] = set()
            for line in plan_path.read_text(encoding="utf-8").splitlines():
                match = install_line.fullmatch(line.strip())
                if match is None:
                    continue
                identity = (match.group(1), match.group(2))
                if identity in ambiguous:
                    raise SupplyError(
                        f"resolved package {identity[0]}={identity[1]} occurs in both "
                        "frozen repositories; repository provenance is ambiguous"
                    )
                try:
                    entries.add(catalog[identity])
                except KeyError as error:
                    raise SupplyError(
                        f"resolver selected {identity[0]}={identity[1]}, which is absent "
                        "from the frozen indexes"
                    ) from error
            if not entries:
                raise SupplyError(f"package set {set_name} resolved an empty closure")
            resolved[set_name] = sorted(entries)
        return resolved


def download_packages(
    *,
    output_dir: Path,
    repositories: dict[str, str],
    architecture: str,
    closures: dict[str, list[tuple[str, str]]],
) -> tuple[list[dict[str, Any]], dict[tuple[str, str], str]]:
    targets = sorted(
        {entry for closure in closures.values() for entry in closure},
        key=lambda item: (item[0], item[1]),
    )

    def fetch(target: tuple[str, str]) -> tuple[str, str, Path, str]:
        repository, filename = target
        url = f"{repositories[repository]}/{architecture}/{filename}"
        destination = output_dir / "repositories" / repository / architecture / filename
        digest, _reused = download(url, destination)
        return repository, url, destination, digest

    with ThreadPoolExecutor(max_workers=min(4, len(targets))) as executor:
        downloaded = list(executor.map(fetch, targets))

    records: list[dict[str, Any]] = []
    id_by_target: dict[tuple[str, str], str] = {}
    seen_ids: set[str] = set()
    for repository, url, package_path, digest in downloaded:
        metadata = parse_pkginfo(package_path)
        if metadata["arch"] != architecture and metadata["arch"] != "noarch":
            raise SupplyError(
                f"package architecture mismatch for {package_path}: {metadata['arch']}"
            )
        package_id = f"{repository}:{metadata['pkgname']}={metadata['pkgver']}"
        target = (repository, package_path.name)
        if target in id_by_target or package_id in seen_ids:
            raise SupplyError(f"duplicate resolved package identity: {package_id}")
        seen_ids.add(package_id)
        id_by_target[target] = package_id
        records.append(
            {
                "id": package_id,
                "name": metadata["pkgname"],
                "version": metadata["pkgver"],
                "constraint": f"{metadata['pkgname']}={metadata['pkgver']}",
                "provides": sorted(metadata["provides"]),
                "architecture": metadata["arch"],
                "repository": repository,
                "url": url,
                "file": package_path.relative_to(output_dir).as_posix(),
                "sha256": digest,
                "size": package_path.stat().st_size,
                "origin": metadata.get("origin", ""),
                "license": metadata.get("license", ""),
            }
        )

    return sorted(records, key=lambda item: item["id"]), id_by_target


def package_provides(package: dict[str, Any], requested_name: str) -> bool:
    if package["name"] == requested_name:
        return True
    return any(provided.split("=", 1)[0] == requested_name for provided in package["provides"])


def build_package_set_records(
    *,
    roots: list[dict[str, Any]],
    package_sets: dict[str, list[str]],
    closures: dict[str, list[tuple[str, str]]],
    packages: list[dict[str, Any]],
    id_by_target: dict[tuple[str, str], str],
    artifact_directory: str,
) -> dict[str, dict[str, Any]]:
    packages_by_id = {package["id"]: package for package in packages}
    records: dict[str, dict[str, Any]] = {}
    for set_name, modules in sorted(package_sets.items()):
        if set_name not in closures:
            continue
        selected_roots = roots_for_modules(roots, modules)
        closure_ids = sorted(id_by_target[target] for target in closures[set_name])
        closure_packages = [packages_by_id[package_id] for package_id in closure_ids]
        locked_roots: list[dict[str, Any]] = []
        for root in selected_roots:
            candidates = [
                package
                for package in closure_packages
                if package["repository"] == root["repository"]
                and package_provides(package, root["name"])
            ]
            if len(candidates) != 1:
                candidate_names = ", ".join(package["name"] for package in candidates)
                raise SupplyError(
                    f"root {root['name']} in {set_name} resolved to "
                    f"{len(candidates)} providers: {candidate_names}"
                )
            package = candidates[0]
            if root["validateSelector"] and not exact_version_matches(
                root["selector"], package["version"]
            ):
                raise SupplyError(
                    f"root {root['name']} resolved version {package['version']} does not "
                    f"match selector {root['selector']}"
                )
            locked_roots.append(
                {
                    "module": root["module"],
                    "requestedName": root["name"],
                    "providerName": package["name"],
                    "repository": package["repository"],
                    "requestedSelector": root["selector"],
                    "version": package["version"],
                    "constraint": package["constraint"],
                }
            )

        closure_repositories = sorted(
            {package_id.split(":", 1)[0] for package_id in closure_ids}
        )
        record: dict[str, Any] = {
            "modules": modules,
            "artifactDirectory": artifact_directory,
            "repositorySubdirs": [
                f"repositories/{repository}" for repository in closure_repositories
            ],
            "roots": locked_roots,
            "packages": [root["constraint"] for root in locked_roots],
            "closure": closure_ids,
        }
        if len(closure_repositories) == 1:
            record["repositorySubdir"] = f"repositories/{closure_repositories[0]}"
        records[set_name] = record
    return records


def main() -> None:
    args = parse_args()
    try:
        platform, architecture = require_platform(args.platform)
        digest = require_oci_digest(args.base_digest, "base digest")
        validate_pinned_image(args.base_image, digest)
        config = require_config(args)
        mapping = load_package_mapping(args.package_map)
        roots, package_sets = expand_package_roots(config, mapping)
        if args.package_sets:
            requested = set(args.package_sets)
            unknown = requested - set(package_sets)
            if unknown:
                raise SupplyError(
                    f"unknown or disabled package sets: {', '.join(sorted(unknown))}"
                )
            package_sets = {
                name: modules
                for name, modules in package_sets.items()
                if name in requested
            }
        if not package_sets:
            raise SupplyError("no enabled package sets were selected")

        repositories = {
            "main": validate_https_repository("main", args.main_repository),
            "extra": validate_https_repository("extra", args.extra_repository),
        }
        artifact_directory = require_relative_path(
            args.artifact_directory, "artifact directory"
        ).as_posix()
        output_dir = args.output_dir.resolve()
        ensure_empty_directory(output_dir, "APK artifact output")
        base_metadata = require_base_metadata(
            args.base_image_metadata,
            pinned_image=args.base_image,
            digest=digest,
            platform=platform,
        )

        repository_records, key_records = prepare_indexes_and_keys(
            output_dir,
            repositories,
            architecture,
            args.base_image,
            platform,
        )
        closures = resolve_package_set_urls(
            base_image=args.base_image,
            platform=platform,
            architecture=architecture,
            artifact_dir=output_dir,
            repositories=repositories,
            repository_records=repository_records,
            roots=roots,
            package_sets=package_sets,
        )
        package_records, id_by_target = download_packages(
            output_dir=output_dir,
            repositories=repositories,
            architecture=architecture,
            closures=closures,
        )
        package_set_records = build_package_set_records(
            roots=roots,
            package_sets=package_sets,
            closures=closures,
            packages=package_records,
            id_by_target=id_by_target,
            artifact_directory=artifact_directory,
        )

        apk_resolution = {
            "schemaVersion": 1,
            "platform": platform,
            "architecture": architecture,
            "artifactDirectory": artifact_directory,
            "baseImage": {
                "pinnedReference": args.base_image,
                "digest": digest,
                "artifact": base_metadata,
            },
            "repositories": repository_records,
            "keys": key_records,
            "packages": package_records,
            "packageSets": package_set_records,
        }
        fragment = {
            "schemaVersion": 1,
            "name": "wolfi-apk-artifacts",
            "version": "1",
            "configSemanticSha256": args.config_sha256,
            "resolved": {"apk": apk_resolution},
        }
        write_json_atomic(args.fragment.resolve(), fragment)
        print(
            f"Resolved {len(package_records)} signed APKs across "
            f"{len(package_set_records)} package sets into {output_dir}"
        )
    except SupplyError as error:
        raise SystemExit(f"ERROR: {error}") from error


if __name__ == "__main__":
    main()
