"""Verified offline profile packaging and loading."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import tarfile
from pathlib import Path

from src.core.hashing import sha256, timestamp, write_json
from src.core.process import run
from src.core.profile import CONFIG_LABEL, LOCK_LABEL, SETTINGS_LABEL, Profile, fail, read_json, relative_path


def profile_labels(profile: Profile) -> dict[str, str]:
    return {
        LOCK_LABEL: profile.digest,
        CONFIG_LABEL: profile.lock["source"]["fileSha256"],
        SETTINGS_LABEL: profile.settings.digest,
    }

def locked_files(profile: Profile) -> dict[str, str]:
    """The exact transfer payload; no directory glob can include another profile."""
    files: dict[str, str] = {}

    def add(value: str, digest: str) -> None:
        path = relative_path(profile.repo, value)
        if not path.is_relative_to(profile.root):
            fail(f"Locked payload lies outside this profile's artifact root: {value}")
        if not re.fullmatch(r"[0-9a-f]{64}", str(digest)):
            fail(f"Missing locked SHA256: {value}")
        if value in files and files[value] != digest:
            fail(f"Conflicting locked hashes: {value}")
        files[value] = digest

    resolved = profile.lock["resolved"]
    apk = resolved["apk"]
    apk_root = apk["artifactDirectory"]
    base = apk["baseImage"]["artifact"]
    add(f"{base['artifactDirectory']}/{base['file']}", base["sha256"])
    for record in apk["repositories"].values():
        add(f"{apk_root}/{record['indexFile']}", record["indexSha256"])
    for record in [*apk["keys"], *apk["packages"]]:
        add(f"{apk_root}/{record['file']}", record["sha256"])
    if resolved.get("vscode"):
        record = resolved["vscode"]
        add(record["archive"], record["sha256"])
    for key in ("kubectl", "rust"):
        if resolved.get(key):
            record = resolved[key]
            add(record["file"], record["sha256"])
    if resolved.get("extensions"):
        extensions = resolved["extensions"]
        for record in [extensions["archive"], extensions["lockfile"], *extensions["packages"]]:
            add(record["file"], record["sha256"])
    if resolved.get("kaniko"):
        kaniko = resolved["kaniko"]
        for record in [kaniko["archive"], kaniko["signature"], *kaniko["sources"]]:
            add(record["file"], record["sha256"])
    if resolved.get("playwright"):
        playwright = resolved["playwright"]
        for record in [playwright["archive"], playwright["testRunner"], *playwright["packages"], *playwright["browsers"]]:
            add(record["file"], record["sha256"])
    return files


def verify_files(repo: Path, files: dict[str, str]) -> None:
    for name, expected in files.items():
        path = relative_path(repo, name)
        if not path.is_file() or sha256(path) != expected:
            fail(f"Missing or changed locked/manifest file: {name}")


def archive_identity(path: Path, reference: str, platform: str, labels: dict[str, str]) -> set[str]:
    """Inspect saved Docker config/OCI identity before loading any image."""
    with tarfile.open(path, "r:") as archive:
        manifest = json.load(archive.extractfile("manifest.json"))
        if not isinstance(manifest, list) or len(manifest) != 1 or manifest[0].get("RepoTags") != [reference]:
            fail(f"Image archive must contain exactly its selected tag: {reference}")
        config_name = manifest[0]["Config"]
        config_bytes = archive.extractfile(config_name).read()
        digest = hashlib.sha256(config_bytes).hexdigest()
        if config_name not in (f"{digest}.json", f"blobs/sha256/{digest}"):
            fail("Saved image config digest does not match its path.")
        config = json.loads(config_bytes)
        if f"{config.get('os')}/{config.get('architecture')}" != platform:
            fail("Saved image has the wrong target platform.")
        actual_labels = config.get("config", {}).get("Labels") or {}
        if any(actual_labels.get(key) != value for key, value in labels.items()):
            fail("Saved image is from a different lock or base digest.")
        identities = {f"sha256:{digest}"}
        try:
            index_source = archive.extractfile("index.json")
        except KeyError:
            index_source = None
        if index_source is not None:
            index = json.load(index_source)
            manifests = index.get("manifests", [])
            if len(manifests) != 1:
                fail("Saved OCI archive must contain one manifest.")

            def descriptor_json(descriptor: dict) -> dict:
                descriptor_digest = descriptor.get("digest", "")
                if not re.fullmatch(r"sha256:[0-9a-f]{64}", descriptor_digest):
                    fail("Saved OCI manifest digest is invalid.")
                data = archive.extractfile(f"blobs/sha256/{descriptor_digest[7:]}").read()
                if hashlib.sha256(data).hexdigest() != descriptor_digest[7:] or len(data) != descriptor.get("size"):
                    fail("Saved OCI descriptor digest/size mismatch.")
                return json.loads(data)

            def visit(descriptor: dict, depth: int = 0) -> set[str]:
                if depth > 3:
                    fail("Saved OCI image has excessive index nesting.")
                descriptor_platform = descriptor.get("platform")
                if descriptor_platform and f"{descriptor_platform.get('os')}/{descriptor_platform.get('architecture')}" != platform:
                    fail("Saved OCI descriptor selects a different platform.")
                value = descriptor_json(descriptor)
                if "manifests" not in value:
                    if value.get("config", {}).get("digest") != f"sha256:{digest}":
                        fail("Saved OCI manifest/config digest mismatch.")
                    return {descriptor["digest"]}
                children = value["manifests"]
                images = [child for child in children if child.get("annotations", {}).get("vnd.docker.reference.type") != "attestation-manifest"]
                if len(images) != 1:
                    fail("Saved OCI index must contain exactly one runnable image.")
                image_descriptor = images[0]
                selected_ids = visit(image_descriptor, depth + 1)
                for child in children:
                    if child is image_descriptor:
                        continue
                    # BuildKit provenance is a non-runnable sibling, not a second
                    # delivered image. Verify its bytes and association as well.
                    if child.get("annotations", {}).get("vnd.docker.reference.digest") != image_descriptor["digest"]:
                        fail("Saved OCI attestation refers to a different image.")
                    attestation = descriptor_json(child)
                    if attestation.get("subject", {}).get("digest", image_descriptor["digest"]) != image_descriptor["digest"]:
                        fail("Saved OCI attestation subject differs from the selected image.")
                return {descriptor["digest"], *selected_ids}

            identities.update(visit(manifests[0]))
        return identities


def package(profile: Profile, args: argparse.Namespace) -> None:
    profile.verify()
    files = locked_files(profile)
    verify_files(profile.repo, files)
    identity = profile.inspect()
    transfer = profile.root / "transfer"
    transfer.mkdir(parents=True, exist_ok=True)
    image_tar = transfer / "image.tar"
    temporary_tar = transfer / ".image.tar.tmp"
    try:
        run("docker", "image", "save", "--output", str(temporary_tar), profile.image)
        if identity["Id"] not in archive_identity(temporary_tar, profile.image, profile.platform, profile_labels(profile)):
            fail("Saved output image differs from the selected immutable image ID.")
        if profile.inspect()["Id"] != identity["Id"]:
            fail("Output tag changed during packaging.")
        temporary_tar.replace(image_tar)
    finally:
        temporary_tar.unlink(missing_ok=True)
    # Sidecar checksums are build inputs, derived directly from locked bytes.
    resolved = profile.lock["resolved"]
    sidecars: dict[str, bytes] = {}
    if resolved.get("vscode"):
        record = resolved["vscode"]
        archive = Path(record["archive"])
        sidecars[str(archive.parent / "SHA256SUMS")] = f"{record['sha256']}  {archive.name}\n".encode()
    if resolved.get("extensions"):
        record = resolved["extensions"]["archive"]
        sidecars[record["checksumFile"]] = f"{record['sha256']}  {Path(record['file']).name}\n".encode()
    for name, data in sidecars.items():
        path = relative_path(profile.repo, name)
        if not path.is_relative_to(profile.root):
            fail("Checksum sidecar escapes selected profile.")
        path.write_bytes(data)
        files[name] = hashlib.sha256(data).hexdigest()
    for path in (profile.config, profile.lock_path, profile.settings.path, image_tar):
        files[str(path.relative_to(profile.repo))] = sha256(path)
    manifest = {"schemaVersion": 3, "generatedAt": timestamp(), "profile": profile.name, "image": profile.image,
                "platform": profile.platform, "imageId": identity["Id"], "lockSha256": profile.digest,
                "configSha256": profile.lock["source"]["fileSha256"],
                "settingsSha256": profile.settings.digest,
                "config": str(profile.config.relative_to(profile.repo)),
                "lock": str(profile.lock_path.relative_to(profile.repo)),
                "settings": str(profile.settings.path.relative_to(profile.repo)),
                "imageTar": str(image_tar.relative_to(profile.repo)), "files": files}
    profile.verify()
    manifest_path = transfer / "manifest.json"
    write_json(manifest_path, manifest)
    output = args.output or profile.repo / f"artifacts-{profile.config.stem}-{profile.platform.replace('/', '-')}.tar.gz"
    output = output.resolve()
    if output.is_relative_to(profile.root):
        fail("Bundle must be outside the selected artifact root.")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f".{output.name}.tmp")
    try:
        with tarfile.open(temporary, "w:gz", compresslevel=6) as bundle:
            for name in sorted([*files, str(manifest_path.relative_to(profile.repo))]):
                bundle.add(profile.repo / name, arcname=name, recursive=False)
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    output.with_name(output.name + ".sha256").write_text(f"{sha256(output)}  {output.name}\n", encoding="utf-8")
    print(f"Packaged {profile.image}: {output}")


def load(profile: Profile, args: argparse.Namespace) -> None:
    profile.verify()
    manifest = read_json(profile.root / "transfer" / "manifest.json")
    expected = {"schemaVersion": 3, "profile": profile.name, "image": profile.image, "platform": profile.platform,
                "lockSha256": profile.digest, "config": str(profile.config.relative_to(profile.repo)),
                "configSha256": profile.lock["source"]["fileSha256"],
                "settingsSha256": profile.settings.digest,
                "lock": str(profile.lock_path.relative_to(profile.repo)),
                "settings": str(profile.settings.path.relative_to(profile.repo))}
    if any(manifest.get(key) != value for key, value in expected.items()):
        fail("Transfer manifest differs from the selected profile/lock/platform.")
    files = manifest.get("files")
    if not isinstance(files, dict):
        fail("Transfer manifest must list exact file hashes.")
    locked = locked_files(profile)
    for name, digest in locked.items():
        if files.get(name) != digest:
            fail(f"Transfer manifest omits or alters a locked artifact: {name}")
    for path in (profile.config, profile.lock_path, profile.settings.path):
        if files.get(str(path.relative_to(profile.repo))) != sha256(path):
            fail("Transfer config or lock bytes differ from the local selected profile.")
    image_tar = relative_path(profile.repo, manifest["imageTar"])
    if image_tar != profile.root / "transfer" / "image.tar" or manifest["imageTar"] not in files:
        fail("Transfer manifest does not identify this profile's saved output image.")
    verify_files(profile.repo, files)
    output_ids = archive_identity(image_tar, profile.image, profile.platform, profile_labels(profile))
    if manifest.get("imageId") not in output_ids:
        fail("Saved output image ID differs from the transfer manifest.")
    base = profile.lock["resolved"]["apk"]["baseImage"]["artifact"]
    base_tar = relative_path(profile.repo, f"{base['artifactDirectory']}/{base['file']}")
    labels = {"devcontainers.wolfi.base.digest": base["digest"], "devcontainers.wolfi.base.source": base["pinnedReference"]}
    base_ids = archive_identity(base_tar, base["localReference"], profile.platform, labels)
    # Every payload and both archive identities have passed before Docker changes.
    profile.verify()
    for path in (base_tar, image_tar):
        run("docker", "load", "--input", str(path))
    loaded_base = profile.inspect(base["localReference"])
    if loaded_base["Id"] not in base_ids or any((loaded_base.get("Config", {}).get("Labels") or {}).get(key) != value for key, value in labels.items()):
        fail("Loaded base image does not match its locked archive identity.")
    # Classic Docker reports the config ID; containerd may report its enclosing
    # manifest/index ID. Both must be derived from this verified archive.
    if profile.inspect()["Id"] not in output_ids:
        fail("Loaded output image does not match the saved archive's immutable identities.")
    print(f"Verified and loaded {profile.image} ({profile.platform}).")
