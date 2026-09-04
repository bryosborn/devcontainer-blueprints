#!/usr/bin/env python3
"""Fetch missing locked Wolfi bytes and verify the complete frozen APK supply."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import tarfile
import tempfile
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

from supply_lib import (
    SupplyError,
    canonical_json_sha256,
    download,
    index_signature_key_names,
    load_json,
    parse_apkindex,
    parse_pkginfo,
    path_beneath,
    platform_key,
    require_oci_digest,
    require_platform,
    require_relative_path,
    require_sha256,
    run,
    sha256_bytes,
    sha256_file,
    validate_https_repository,
    validate_pinned_image,
)


SCRIPT_DIR = Path(__file__).resolve().parent
MATERIALIZER = SCRIPT_DIR / "materialize-base-image.py"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", required=True, type=Path)
    parser.add_argument("--config-sha256", required=True)
    parser.add_argument("--artifact-root", required=True, type=Path)
    return parser.parse_args()


def require_mapping(value: Any, location: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise SupplyError(f"{location} must be an object")
    return value


def require_array(value: Any, location: str) -> list[Any]:
    if not isinstance(value, list):
        raise SupplyError(f"{location} must be an array")
    return value


def require_string(value: Any, location: str) -> str:
    if not isinstance(value, str) or not value:
        raise SupplyError(f"{location} must be a non-empty string")
    return value


def verify_file(path: Path, expected_hash: Any, expected_size: Any, location: str) -> None:
    digest = require_sha256(expected_hash, f"{location} SHA256")
    if not isinstance(expected_size, int) or expected_size <= 0:
        raise SupplyError(f"{location} size must be a positive integer")
    if path.is_symlink() or not path.is_file():
        raise SupplyError(f"{location} is missing or is not a regular file: {path}")
    actual_size = path.stat().st_size
    if actual_size != expected_size:
        raise SupplyError(
            f"{location} size mismatch: expected {expected_size}, got {actual_size}"
        )
    actual_hash = sha256_file(path)
    if actual_hash != digest:
        raise SupplyError(
            f"{location} SHA256 mismatch: expected {digest}, got {actual_hash}"
        )


def fetch_missing_locked_file(
    path: Path,
    *,
    url: str,
    expected_hash: Any,
    expected_size: Any,
    location: str,
) -> bool:
    require_sha256(expected_hash, f"{location} SHA256")
    if path.exists() or path.is_symlink():
        verify_file(path, expected_hash, expected_size, location)
        return False
    download(url, path, expected_sha256=expected_hash)
    verify_file(path, expected_hash, expected_size, location)
    return True


def inspect_local_base(reference: str) -> dict[str, Any] | None:
    result = run(
        ["docker", "image", "inspect", reference],
        check=False,
        capture_output=True,
    )
    if result.returncode != 0:
        return None
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise SupplyError(f"docker returned invalid image metadata: {error}") from error
    if not isinstance(value, list) or len(value) != 1 or not isinstance(value[0], dict):
        raise SupplyError("docker returned unexpected image metadata")
    return value[0]


def verify_local_base(
    metadata: dict[str, Any],
    *,
    platform: str,
    pinned_reference: str,
    digest: str,
    expected_image_ids: set[str] | None = None,
) -> None:
    actual_platform = f"{metadata.get('Os')}/{metadata.get('Architecture')}"
    if actual_platform != platform:
        raise SupplyError(
            f"local frozen base platform mismatch: expected {platform}, got {actual_platform}"
        )
    labels = metadata.get("Config", {}).get("Labels") or {}
    if labels.get("devcontainers.wolfi.base.digest") != digest:
        raise SupplyError("local frozen base does not carry the locked source digest label")
    if labels.get("devcontainers.wolfi.base.source") != pinned_reference:
        raise SupplyError("local frozen base does not carry the locked source reference label")
    if expected_image_ids is not None and metadata.get("Id") not in expected_image_ids:
        raise SupplyError(
            "local frozen base image ID differs from the verified saved archive"
        )


def verify_base_archive(
    path: Path,
    *,
    local_reference: str,
    platform: str,
    pinned_reference: str,
    digest: str,
) -> set[str]:
    try:
        with tarfile.open(path, mode="r:") as archive:
            manifest_source = archive.extractfile("manifest.json")
            if manifest_source is None:
                raise KeyError("manifest.json")
            manifest = json.loads(manifest_source.read().decode("utf-8"))
            if not isinstance(manifest, list) or len(manifest) != 1:
                raise SupplyError("base archive must contain exactly one image manifest")
            entry = require_mapping(manifest[0], "base archive manifest")
            tags = require_array(entry.get("RepoTags"), "base archive RepoTags")
            if tags != [local_reference]:
                raise SupplyError("base archive does not contain only its locked local tag")
            config_name = require_relative_path(
                entry.get("Config"), "base archive config path"
            ).as_posix()
            config_path = Path(config_name)
            if len(config_path.parts) == 3 and config_path.parts[:2] == (
                "blobs",
                "sha256",
            ):
                config_hash = config_path.parts[2]
            elif len(config_path.parts) == 1 and config_path.suffix == ".json":
                config_hash = config_path.stem
            else:
                raise SupplyError("base archive has a noncanonical image config path")
            if len(config_hash) != 64 or any(
                character not in "0123456789abcdef" for character in config_hash
            ):
                raise SupplyError("base archive has a noncanonical image config digest")
            config_source = archive.extractfile(config_name)
            if config_source is None:
                raise KeyError(config_name)
            config_bytes = config_source.read()
            if sha256_bytes(config_bytes) != config_hash:
                raise SupplyError("base archive image config digest is invalid")
            config = require_mapping(
                json.loads(config_bytes.decode("utf-8")), "base archive image config"
            )
            expected_image_ids = {f"sha256:{config_hash}"}

            try:
                index_source = archive.extractfile("index.json")
            except KeyError:
                index_source = None
            if index_source is not None:
                index = require_mapping(
                    json.loads(index_source.read().decode("utf-8")), "base OCI index"
                )
                descriptors = require_array(index.get("manifests"), "base OCI index manifests")
                if len(descriptors) != 1:
                    raise SupplyError("base OCI archive must contain one manifest descriptor")
                descriptor = require_mapping(descriptors[0], "base OCI manifest descriptor")
                manifest_digest = require_oci_digest(
                    descriptor.get("digest"), "base OCI manifest digest"
                )
                manifest_hash = manifest_digest.removeprefix("sha256:")
                manifest_source = archive.extractfile(f"blobs/sha256/{manifest_hash}")
                if manifest_source is None:
                    raise KeyError(f"blobs/sha256/{manifest_hash}")
                manifest_bytes = manifest_source.read()
                if sha256_bytes(manifest_bytes) != manifest_hash:
                    raise SupplyError("base OCI manifest digest is invalid")
                manifest = require_mapping(
                    json.loads(manifest_bytes.decode("utf-8")), "base OCI manifest"
                )
                manifest_config = require_mapping(
                    manifest.get("config"), "base OCI manifest config"
                )
                if manifest_config.get("digest") != f"sha256:{config_hash}":
                    raise SupplyError("base OCI manifest and image config disagree")
                expected_image_ids.add(manifest_digest)
    except SupplyError:
        raise
    except (
        OSError,
        tarfile.TarError,
        KeyError,
        UnicodeDecodeError,
        json.JSONDecodeError,
    ) as error:
        raise SupplyError(f"unable to inspect frozen base archive {path}: {error}") from error
    verify_local_base(
        {
            "Os": config.get("os"),
            "Architecture": config.get("architecture"),
            "Config": config.get("config"),
            "Id": f"sha256:{config_hash}",
        },
        platform=platform,
        pinned_reference=pinned_reference,
        digest=digest,
        expected_image_ids=expected_image_ids,
    )
    return expected_image_ids


def regenerate_base_artifact(
    *, artifact: dict[str, Any], platform_root: Path, platform: str
) -> None:
    with tempfile.TemporaryDirectory(prefix="wolfi-frozen-base-") as temporary_name:
        temporary_root = Path(temporary_name)
        output_dir = temporary_root / "docker-images"
        metadata_path = temporary_root / "base-image.artifact.json"
        run(
            [
                "python3",
                str(MATERIALIZER),
                "--pinned-image",
                artifact["pinnedReference"],
                "--expected-digest",
                artifact["digest"],
                "--platform",
                platform,
                "--output-dir",
                str(output_dir),
                "--artifact-directory",
                artifact["artifactDirectory"],
                "--metadata",
                str(metadata_path),
                "--expected-tar-sha256",
                artifact["sha256"],
            ]
        )
        regenerated = load_json(metadata_path, "regenerated base metadata")
        if regenerated != artifact:
            raise SupplyError("regenerated base-image metadata differs from the lock")
        source = output_dir / Path(artifact["file"]).name
        destination = path_beneath(platform_root, artifact["file"], "base artifact file")
        destination.parent.mkdir(parents=True, exist_ok=True)
        os.replace(source, destination)


def ensure_base_image(
    *, artifact: dict[str, Any], platform_root: Path, platform: str
) -> None:
    base_file = path_beneath(platform_root, artifact["file"], "base artifact file")
    local_reference = require_string(artifact.get("localReference"), "base localReference")
    pinned_reference = require_string(
        artifact.get("pinnedReference"), "base pinnedReference"
    )
    digest = require_oci_digest(artifact.get("digest"), "base artifact digest")
    validate_pinned_image(pinned_reference, digest)

    local_metadata = inspect_local_base(local_reference)
    if local_metadata is not None:
        verify_local_base(
            local_metadata,
            platform=platform,
            pinned_reference=pinned_reference,
            digest=digest,
        )

    if not base_file.exists() and not base_file.is_symlink():
        if local_metadata is None:
            regenerate_base_artifact(
                artifact=artifact, platform_root=platform_root, platform=platform
            )
        else:
            base_file.parent.mkdir(parents=True, exist_ok=True)
            temporary = base_file.with_name(f".{base_file.name}.{uuid.uuid4().hex}.tmp")
            try:
                run(
                    [
                        "docker",
                        "image",
                        "save",
                        "--output",
                        str(temporary),
                        local_reference,
                    ]
                )
                verify_file(
                    temporary,
                    artifact.get("sha256"),
                    artifact.get("size"),
                    "regenerated base artifact",
                )
                os.replace(temporary, base_file)
            finally:
                temporary.unlink(missing_ok=True)

    verify_file(
        base_file,
        artifact.get("sha256"),
        artifact.get("size"),
        "base artifact",
    )
    archive_image_ids = verify_base_archive(
        base_file,
        local_reference=local_reference,
        platform=platform,
        pinned_reference=pinned_reference,
        digest=digest,
    )
    if local_metadata is not None:
        verify_local_base(
            local_metadata,
            platform=platform,
            pinned_reference=pinned_reference,
            digest=digest,
            expected_image_ids=archive_image_ids,
        )
    if local_metadata is None:
        run(["docker", "image", "load", "--input", str(base_file)])
        loaded = inspect_local_base(local_reference)
        if loaded is None:
            raise SupplyError("loaded base artifact did not restore its locked local tag")
        verify_local_base(
            loaded,
            platform=platform,
            pinned_reference=pinned_reference,
            digest=digest,
            expected_image_ids=archive_image_ids,
        )


def extract_base_keys(base_image: str, platform: str, destination: Path) -> None:
    container_name = f"wolfi-frozen-keys-{uuid.uuid4().hex[:12]}"
    destination.mkdir(parents=True, exist_ok=True)
    try:
        run(
            [
                "docker",
                "create",
                "--name",
                container_name,
                "--pull",
                "never",
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
            ["docker", "container", "rm", "--force", container_name],
            check=False,
            capture_output=True,
        )


def ensure_keys(
    *, records: list[Any], apk_root: Path, base_image: str, platform: str
) -> None:
    missing = False
    for index, raw_record in enumerate(records):
        record = require_mapping(raw_record, f"apk.keys[{index}]")
        path = path_beneath(apk_root, record.get("file"), f"apk.keys[{index}].file")
        if not path.exists() and not path.is_symlink():
            missing = True
            continue
        verify_file(path, record.get("sha256"), record.get("size"), f"APK key {index}")
    if missing:
        with tempfile.TemporaryDirectory(prefix="wolfi-frozen-keys-") as temporary_name:
            extracted = Path(temporary_name)
            extract_base_keys(base_image, platform, extracted)
            for index, raw_record in enumerate(records):
                record = require_mapping(raw_record, f"apk.keys[{index}]")
                destination = path_beneath(
                    apk_root, record.get("file"), f"apk.keys[{index}].file"
                )
                if destination.exists() or destination.is_symlink():
                    continue
                name = require_string(record.get("name"), f"apk.keys[{index}].name")
                if Path(name).name != name:
                    raise SupplyError(f"unsafe locked APK key name: {name}")
                source = extracted / name
                verify_file(
                    source,
                    record.get("sha256"),
                    record.get("size"),
                    f"base-image APK key {name}",
                )
                destination.parent.mkdir(parents=True, exist_ok=True)
                temporary = destination.with_name(
                    f".{destination.name}.{uuid.uuid4().hex}.tmp"
                )
                shutil.copyfile(source, temporary)
                os.replace(temporary, destination)
    for index, raw_record in enumerate(records):
        record = require_mapping(raw_record, f"apk.keys[{index}]")
        path = path_beneath(apk_root, record.get("file"), f"apk.keys[{index}].file")
        verify_file(path, record.get("sha256"), record.get("size"), f"APK key {index}")
        if record.get("fingerprintSha256") != record.get("sha256"):
            raise SupplyError(f"APK key {index} fingerprint and file hash differ")


def verify_index_signatures(
    *, apk_root: Path, local_base: str, platform: str, repositories: list[str]
) -> None:
    container_name = f"wolfi-frozen-index-{uuid.uuid4().hex[:12]}"
    quoted_repositories = " ".join(
        f"file:///artifacts/repositories/{name}" for name in repositories
    )
    command = (
        "set -eu; mkdir -p /work/cache; "
        f"printf '%s\\n' {quoted_repositories} > /work/repositories.list; "
        "apk --no-network --cache-dir /work/cache --keys-dir /artifacts/keys "
        "--repositories-file /work/repositories.list update"
    )
    result = None
    try:
        run(
            [
                "docker",
                "create",
                "--name",
                container_name,
                "--pull",
                "never",
                "--network",
                "none",
                "--platform",
                platform,
                "--entrypoint",
                "/bin/sh",
                local_base,
                "-c",
                command,
            ],
            capture_output=True,
        )
        run(
            ["docker", "cp", f"{apk_root.resolve()}/.", f"{container_name}:/artifacts"],
            capture_output=True,
        )
        result = run(
            ["docker", "start", "--attach", container_name],
            check=False,
            capture_output=True,
        )
    finally:
        run(
            ["docker", "container", "rm", "--force", container_name],
            check=False,
            capture_output=True,
        )
    if result is None or result.returncode != 0:
        detail = "" if result is None else (result.stderr or result.stdout).strip()
        raise SupplyError(f"offline APK index signature verification failed: {detail}")


def validate_and_fetch_supply(
    *, lock: dict[str, Any], expected_hash: str, artifact_root: Path
) -> tuple[dict[str, Any], Path, str, str]:
    if lock.get("schemaVersion") != 1:
        raise SupplyError("Wolfi lock schemaVersion must be 1")
    source = require_mapping(lock.get("source"), "lock.source")
    if source.get("semanticSha256") != expected_hash:
        raise SupplyError("lock semantic hash does not match --config-sha256")
    config = require_mapping(lock.get("config"), "lock.config")
    if canonical_json_sha256(config) != expected_hash:
        raise SupplyError("embedded lock config does not match its semantic SHA256")
    configured_artifact_root = require_relative_path(
        require_mapping(config.get("artifacts"), "lock.config.artifacts").get("root"),
        "lock.config.artifacts.root",
    ).as_posix()
    platform, architecture = require_platform(
        require_mapping(config.get("images"), "lock.config.images").get("platform")
    )
    slug = platform_key(platform)
    resolved = require_mapping(lock.get("resolved"), "lock.resolved")
    base_resolution = require_mapping(resolved.get("baseImage"), "lock.resolved.baseImage")
    wolfi_config = require_mapping(config.get("wolfi"), "lock.config.wolfi")
    if base_resolution.get("requested") != wolfi_config.get("baseImage"):
        raise SupplyError("resolved base-image selector differs from config")
    if base_resolution.get("platform") != platform:
        raise SupplyError("resolved base-image platform differs from config")
    apk = require_mapping(resolved.get("apk"), "lock.resolved.apk")
    if apk.get("schemaVersion") != 1:
        raise SupplyError("lock.resolved.apk.schemaVersion must be 1")
    if apk.get("platform") != platform or apk.get("architecture") != architecture:
        raise SupplyError("locked APK platform/architecture is inconsistent with config")
    expected_apk_directory = f"{configured_artifact_root}/{slug}/apk"
    if apk.get("artifactDirectory") != expected_apk_directory:
        raise SupplyError("locked APK artifactDirectory is not the configured platform path")

    apk_root = artifact_root.resolve() / slug / "apk"
    platform_root = artifact_root.resolve() / slug
    apk_root.mkdir(parents=True, exist_ok=True)
    base = require_mapping(apk.get("baseImage"), "lock.resolved.apk.baseImage")
    artifact = require_mapping(base.get("artifact"), "lock.resolved.apk.baseImage.artifact")
    if artifact.get("schemaVersion") != 1 or artifact.get("platform") != platform:
        raise SupplyError("locked base artifact metadata is invalid")
    expected_base_directory = f"{configured_artifact_root}/{slug}"
    if artifact.get("artifactDirectory") != expected_base_directory:
        raise SupplyError("locked base artifactDirectory is not the configured platform path")
    pinned_reference = require_string(
        base_resolution.get("pinnedReference"), "lock.resolved.baseImage.pinnedReference"
    )
    digest = require_oci_digest(
        base_resolution.get("digest"), "lock.resolved.baseImage.digest"
    )
    validate_pinned_image(pinned_reference, digest)
    if base.get("pinnedReference") != pinned_reference or base.get("digest") != digest:
        raise SupplyError("locked APK base pin differs from resolved.baseImage")
    if artifact.get("pinnedReference") != pinned_reference or artifact.get("digest") != digest:
        raise SupplyError("base artifact pin differs from resolved.baseImage")

    ensure_base_image(artifact=artifact, platform_root=platform_root, platform=platform)

    configured_repositories = require_mapping(
        wolfi_config.get("repositories"),
        "lock.config.wolfi.repositories",
    )
    repositories = require_mapping(apk.get("repositories"), "lock.resolved.apk.repositories")
    if set(repositories) != {"main", "extra"}:
        raise SupplyError("locked APK repositories must contain exactly main and extra")
    repository_records: dict[str, dict[str, Any]] = {}
    for name in ("main", "extra"):
        record = require_mapping(repositories[name], f"apk.repositories.{name}")
        url = validate_https_repository(name, record.get("url"))
        if configured_repositories.get(name) != url:
            raise SupplyError(f"locked {name} repository differs from config")
        if record.get("architecture") != architecture:
            raise SupplyError(f"locked {name} repository architecture mismatch")
        expected_url = f"{url}/{architecture}/APKINDEX.tar.gz"
        expected_file = f"repositories/{name}/{architecture}/APKINDEX.tar.gz"
        if record.get("indexUrl") != expected_url or record.get("indexFile") != expected_file:
            raise SupplyError(f"locked {name} index coordinates are not canonical")
        repository_records[name] = record

    package_records = require_array(apk.get("packages"), "lock.resolved.apk.packages")
    fetches: list[tuple[Path, str, Any, Any, str]] = []
    for name, record in repository_records.items():
        fetches.append(
            (
                path_beneath(apk_root, record["indexFile"], f"{name} indexFile"),
                record["indexUrl"],
                record.get("indexSha256"),
                record.get("indexSize"),
                f"{name} signed index",
            )
        )
    for index, raw_record in enumerate(package_records):
        record = require_mapping(raw_record, f"apk.packages[{index}]")
        repository = record.get("repository")
        if repository not in repository_records:
            raise SupplyError(f"apk.packages[{index}] has an unknown repository")
        name = require_string(record.get("name"), f"apk.packages[{index}].name")
        version = require_string(record.get("version"), f"apk.packages[{index}].version")
        filename = f"{name}-{version}.apk"
        expected_file = f"repositories/{repository}/{architecture}/{filename}"
        expected_url = f"{repository_records[repository]['url']}/{architecture}/{filename}"
        if record.get("file") != expected_file or record.get("url") != expected_url:
            raise SupplyError(f"apk.packages[{index}] coordinates are not canonical")
        fetches.append(
            (
                path_beneath(apk_root, record["file"], f"apk.packages[{index}].file"),
                record["url"],
                record.get("sha256"),
                record.get("size"),
                f"APK {name}={version}",
            )
        )

    def fetch_one(item: tuple[Path, str, Any, Any, str]) -> bool:
        path, url, digest_value, size, location = item
        return fetch_missing_locked_file(
            path,
            url=url,
            expected_hash=digest_value,
            expected_size=size,
            location=location,
        )

    with ThreadPoolExecutor(max_workers=min(8, len(fetches))) as executor:
        fetched_count = sum(executor.map(fetch_one, fetches))

    keys = require_array(apk.get("keys"), "lock.resolved.apk.keys")
    if not keys:
        raise SupplyError("lock.resolved.apk.keys must not be empty")
    local_base = require_string(artifact.get("localReference"), "base localReference")
    ensure_keys(
        records=keys, apk_root=apk_root, base_image=local_base, platform=platform
    )

    key_by_name: dict[str, dict[str, Any]] = {}
    for index, raw_record in enumerate(keys):
        record = require_mapping(raw_record, f"apk.keys[{index}]")
        name = require_string(record.get("name"), f"apk.keys[{index}].name")
        if name in key_by_name:
            raise SupplyError(f"duplicate locked APK key: {name}")
        key_by_name[name] = record

    catalogs: dict[str, set[tuple[str, str]]] = {}
    for name, record in repository_records.items():
        index_path = path_beneath(apk_root, record["indexFile"], f"{name} indexFile")
        actual_signatures = index_signature_key_names(index_path)
        if actual_signatures != record.get("signatureKeyNames"):
            raise SupplyError(f"{name} index signature names differ from the lock")
        trusted_names = require_array(
            record.get("trustedSignatureKeyNames"),
            f"apk.repositories.{name}.trustedSignatureKeyNames",
        )
        expected_fingerprints: list[str] = []
        for key_name in trusted_names:
            if key_name not in actual_signatures or key_name not in key_by_name:
                raise SupplyError(f"{name} index references an unavailable trusted key")
            expected_fingerprints.append(key_by_name[key_name]["fingerprintSha256"])
        if expected_fingerprints != record.get("signatureKeyFingerprintsSha256"):
            raise SupplyError(f"{name} trusted key fingerprints differ from the lock")
        catalogs[name] = {
            (entry["name"], entry["version"]) for entry in parse_apkindex(index_path)
        }

    packages_by_id: dict[str, dict[str, Any]] = {}
    for index, raw_record in enumerate(package_records):
        record = require_mapping(raw_record, f"apk.packages[{index}]")
        repository = record["repository"]
        name = record["name"]
        version = record["version"]
        expected_id = f"{repository}:{name}={version}"
        if record.get("id") != expected_id or record.get("constraint") != f"{name}={version}":
            raise SupplyError(f"apk.packages[{index}] identity fields are inconsistent")
        if expected_id in packages_by_id:
            raise SupplyError(f"duplicate locked APK identity: {expected_id}")
        if (name, version) not in catalogs[repository]:
            raise SupplyError(f"{expected_id} is absent from its locked signed index")
        package_path = path_beneath(
            apk_root, record["file"], f"apk.packages[{index}].file"
        )
        metadata = parse_pkginfo(package_path)
        if (
            metadata["pkgname"] != name
            or metadata["pkgver"] != version
            or metadata["arch"] != record.get("architecture")
            or sorted(metadata["provides"]) != record.get("provides")
        ):
            raise SupplyError(f"{expected_id} package metadata differs from the lock")
        if metadata["arch"] not in {architecture, "noarch"}:
            raise SupplyError(f"{expected_id} has the wrong architecture")
        packages_by_id[expected_id] = record

    package_sets = require_mapping(apk.get("packageSets"), "lock.resolved.apk.packageSets")
    for set_name, raw_set in package_sets.items():
        package_set = require_mapping(raw_set, f"apk.packageSets.{set_name}")
        if package_set.get("artifactDirectory") != expected_apk_directory:
            raise SupplyError(f"package set {set_name} artifactDirectory mismatch")
        closure = require_array(package_set.get("closure"), f"package set {set_name} closure")
        if not closure or len(set(closure)) != len(closure):
            raise SupplyError(f"package set {set_name} closure is empty or duplicated")
        unknown = set(closure) - set(packages_by_id)
        if unknown:
            raise SupplyError(
                f"package set {set_name} references unknown APKs: {', '.join(sorted(unknown))}"
            )
        roots = require_array(package_set.get("roots"), f"package set {set_name} roots")
        constraints = require_array(
            package_set.get("packages"), f"package set {set_name} packages"
        )
        if constraints != [require_mapping(root, "package-set root").get("constraint") for root in roots]:
            raise SupplyError(f"package set {set_name} root constraints are inconsistent")
        for root in roots:
            root_record = require_mapping(root, f"package set {set_name} root")
            identity = (
                f"{root_record.get('repository')}:"
                f"{root_record.get('providerName')}={root_record.get('version')}"
            )
            if identity not in closure or root_record.get("constraint") != (
                f"{root_record.get('providerName')}={root_record.get('version')}"
            ):
                raise SupplyError(f"package set {set_name} has an invalid locked root")

    verify_index_signatures(
        apk_root=apk_root,
        local_base=local_base,
        platform=platform,
        repositories=sorted(repository_records),
    )
    print(
        f"Verified {len(package_records)} frozen APKs and {len(package_sets)} package sets "
        f"({fetched_count} missing files fetched)."
    )
    return apk, apk_root, local_base, platform


def main() -> None:
    args = parse_args()
    try:
        expected_hash = require_sha256(args.config_sha256, "config SHA256")
        lock = load_json(args.lock.resolve(), "Wolfi lock")
        if not isinstance(lock, dict):
            raise SupplyError("Wolfi lock must be an object")
        validate_and_fetch_supply(
            lock=lock,
            expected_hash=expected_hash,
            artifact_root=args.artifact_root,
        )
    except SupplyError as error:
        raise SystemExit(f"ERROR: {error}") from error


if __name__ == "__main__":
    main()
