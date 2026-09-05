#!/usr/bin/env python3
"""Signed Kaniko release selection and reproducible, frozen payload extraction."""
from __future__ import annotations

import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import platform as host_platform
import re
import shutil
import struct
import subprocess
import tarfile
import time
import urllib.error
import urllib.request
import uuid

REPOSITORY = "ghcr.io/osscontainertools/kaniko"
REGISTRY = "https://ghcr.io/v2/osscontainertools/kaniko"
ISSUER = "https://token.actions.githubusercontent.com"
COSIGN_VERSION = "3.1.3"
COSIGN_HASHES = {
    "x86_64": ("amd64", "4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71"),
    "aarch64": ("arm64", "c5d324e091826b0d7a78eb16fef316450b4eb9aaec045611c08ba06f5e73220a"),
}
PAYLOADS = {"kaniko/executor": 0o755, "kaniko/tini": 0o755,
            "kaniko/ssl/certs/ca-certificates.crt": 0o644}
SHA256 = re.compile(r"^[a-f0-9]{64}$")
DIGEST = re.compile(r"^sha256:[a-f0-9]{64}$")
MEDIA = ", ".join(("application/vnd.oci.image.index.v1+json",
                    "application/vnd.oci.image.manifest.v1+json",
                    "application/vnd.docker.distribution.manifest.list.v2+json",
                    "application/vnd.docker.distribution.manifest.v2+json"))


def fail(message):
    raise SystemExit(f"ERROR: Kaniko {message}")


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def checked_path(root, relative):
    if not isinstance(relative, str) or not relative or "\\" in relative:
        fail("artifact path must be relative POSIX text")
    value = PurePosixPath(relative)
    if value.is_absolute() or value.as_posix() != relative or ".." in value.parts:
        fail("artifact path must be normalized and repository-relative")
    result = (root / relative).resolve()
    if root.resolve() not in result.parents:
        fail("artifact path escapes repository")
    return result


def file_record(path, root, **extra):
    return {"file": path.resolve().relative_to(root.resolve()).as_posix(),
            "sha256": sha(path), "size": path.stat().st_size, **extra}


def verified(record, root):
    if not isinstance(record, dict) or not SHA256.fullmatch(str(record.get("sha256", ""))):
        fail("record requires a SHA256")
    path = checked_path(root, record.get("file"))
    if not path.is_file() or sha(path) != record["sha256"] or path.stat().st_size != record.get("size"):
        fail(f"missing or modified frozen artifact: {path}")
    return path


class HTTPSRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        if not newurl.startswith("https://"):
            fail("refuses non-HTTPS redirect")
        redirected = super().redirect_request(request, fp, code, message, headers, newurl)
        if redirected is not None and not newurl.startswith(REGISTRY + "/"):
            redirected.remove_header("Authorization")
        return redirected


class Registry:
    """Read only public GHCR bytes; no Docker credentials or mutable frozen tags."""
    def __init__(self):
        self.token = None
        self.opener = urllib.request.build_opener(HTTPSRedirect())

    def fetch(self, url, expected=None):
        if not url.startswith("https://"):
            fail("refuses non-HTTPS URL")
        if expected is not None and not SHA256.fullmatch(expected):
            fail("download requires a valid SHA256")
        error = None
        for attempt in range(5):
            try:
                headers = {"User-Agent": "wolfi-kaniko-supply/1", "Accept": MEDIA}
                if url.startswith(REGISTRY + "/"):
                    if self.token is None:
                        self.token = json.loads(self.fetch(
                            "https://ghcr.io/token?scope=repository:osscontainertools/kaniko:pull&service=ghcr.io"))["token"]
                    headers["Authorization"] = "Bearer " + self.token
                with self.opener.open(urllib.request.Request(url, headers=headers), timeout=120) as response:
                    if not response.geturl().startswith("https://"):
                        fail("refuses non-HTTPS redirect")
                    data = response.read()
                if expected and hashlib.sha256(data).hexdigest() != expected:
                    fail(f"SHA256 mismatch for {url}")
                return data
            except (OSError, urllib.error.URLError) as exc:
                if isinstance(exc, urllib.error.HTTPError) and exc.code not in (408, 429, 500, 502, 503, 504):
                    fail(f"HTTP {exc.code} downloading {url}")
                error = exc
                if attempt < 4:
                    time.sleep(min(2 ** attempt, 8))
        fail(f"download failed after five attempts: {url}: {error}")

    def cache(self, url, path, expected=None):
        if path.is_file():
            if expected and sha(path) != expected:
                fail(f"cached artifact hash mismatch: {path}")
            if expected:
                return
        data = self.fetch(url, expected)
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
        try:
            temporary.write_bytes(data)
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)


def cosign_binary(client, repo_root):
    found = shutil.which("cosign")
    if found:
        version = json.loads(subprocess.check_output([found, "version", "--json"], text=True))
        if re.fullmatch(r"v3\.\d+\.\d+", version.get("gitVersion", "")):
            return found, version
        fail("signature verification requires Cosign 3")
    architecture = COSIGN_HASHES.get(host_platform.machine())
    if architecture is None:
        fail("Cosign bootstrap supports x86_64 and aarch64 preparation hosts")
    arch, expected = architecture
    binary = repo_root / ".tmp" / "wolfi-tools" / f"cosign-{COSIGN_VERSION}-{arch}"
    client.cache(f"https://github.com/sigstore/cosign/releases/download/v{COSIGN_VERSION}/cosign-linux-{arch}", binary, expected)
    binary.chmod(0o755)
    version = json.loads(subprocess.check_output([str(binary), "version", "--json"], text=True))
    if version.get("gitVersion") != f"v{COSIGN_VERSION}":
        fail("downloaded Cosign version differs from its preparation pin")
    return str(binary), version


def verify_signature(client, root, index_digest, version, destination):
    binary, provenance = cosign_binary(client, root)
    identity = f"https://github.com/osscontainertools/kaniko/.github/workflows/images.yaml@refs/tags/v{version}"
    command = [binary, "verify", "--certificate-identity", identity,
               "--certificate-oidc-issuer", ISSUER, f"{REPOSITORY}@{index_digest}"]
    result = subprocess.run(command, check=True, capture_output=True, text=True, timeout=300)
    signatures = json.loads(result.stdout)
    if not isinstance(signatures, list) or not signatures or not any(
        s.get("critical", {}).get("image", {}).get("docker-manifest-digest") == index_digest for s in signatures
    ):
        fail("Cosign output does not bind the verified release digest")
    evidence = {"image": f"{REPOSITORY}@{index_digest}", "identity": identity, "issuer": ISSUER,
                "cosign": provenance, "signatures": signatures, "verificationLog": result.stderr}
    destination.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
    return {**file_record(destination, root), "identity": identity, "issuer": ISSUER,
            "cosignVersion": provenance["gitVersion"]}


def validate_elf(data, platform, name):
    machine = {"linux/amd64": 62, "linux/arm64": 183}[platform]
    if len(data) < 64 or data[:6] != b"\x7fELF\x02\x01" or struct.unpack_from("<H", data, 18)[0] != machine:
        fail(f"{name} must be an ELF executable for {platform}")
    offset, entry_size, count = struct.unpack_from("<Q", data, 32)[0], *struct.unpack_from("<HH", data, 54)
    if entry_size < 4 or offset + entry_size * count > len(data):
        fail(f"invalid ELF program headers in {name}")
    if any(struct.unpack_from("<I", data, offset + i * entry_size)[0] == 3 for i in range(count)):
        fail(f"{name} must be static, without an ELF interpreter")


def extract_payload(layers, platform):
    selected = {}
    for layer in layers:
        additions = {}
        with tarfile.open(layer, "r:*") as archive:
            for member in archive:
                name = member.name.removeprefix("./").rstrip("/")
                path = PurePosixPath(name)
                if path.is_absolute() or ".." in path.parts:
                    fail("unsafe source image layer path")
                # Apply whiteouts to the selected paths without extracting a rootfs.
                if path.name == ".wh..wh..opq":
                    prefix = "" if str(path.parent) == "." else str(path.parent) + "/"
                    selected = {k: v for k, v in selected.items() if not k.startswith(prefix)}
                elif path.name.startswith(".wh."):
                    removed = str(path.parent / path.name[4:])
                    selected = {k: v for k, v in selected.items() if k != removed and not k.startswith(removed + "/")}
                elif name in PAYLOADS:
                    if not member.isfile():
                        fail(f"selected source payload must be a regular file: {name}")
                    additions[name] = archive.extractfile(member).read()
        selected.update(additions)
    if set(selected) != set(PAYLOADS):
        fail("release image lacks executor, tini, or certificate bundle")
    for name in ("kaniko/executor", "kaniko/tini"):
        validate_elf(selected[name], platform, name)
    if b"-----BEGIN CERTIFICATE-----" not in selected["kaniko/ssl/certs/ca-certificates.crt"]:
        fail("certificate payload is not a PEM bundle")
    return selected


def write_payload(destination, selected):
    temporary = destination.with_name(f".{destination.name}.{uuid.uuid4().hex}.tmp")
    try:
        with temporary.open("wb") as stream, gzip.GzipFile(filename="", fileobj=stream, mode="wb", mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as archive:
                for name, data in sorted(selected.items()):
                    info = tarfile.TarInfo(name.removeprefix("kaniko/"))
                    info.size, info.mode, info.mtime = len(data), PAYLOADS[name], 0
                    archive.addfile(info, io.BytesIO(data))
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def resolve_kaniko(config, artifact_root, repo_root):
    """Return resolved.kaniko; called exclusively during update-lock."""
    root, artifact_root = Path(repo_root).resolve(), Path(artifact_root).resolve()
    version, target = config["kaniko"]["version"], config["image"]["platform"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or target not in ("linux/amd64", "linux/arm64"):
        fail("requires an exact release version and supported platform")
    client, descriptors = Registry(), []
    directory = artifact_root / "kaniko" / f"v{version}" / target.replace("/", "-")
    directory.mkdir(parents=True, exist_ok=True)

    def descriptor(kind, digest, size=None):
        if not DIGEST.fullmatch(digest):
            fail("invalid OCI digest")
        url = f"{REGISTRY}/{'manifests' if kind in ('index', 'manifest') else 'blobs'}/{digest}"
        path = directory / "source" / digest.removeprefix("sha256:")
        client.cache(url, path, digest.removeprefix("sha256:"))
        record = file_record(path, root, kind=kind, digest=digest, url=url)
        if size is not None and record["size"] != size:
            fail("OCI descriptor size mismatch")
        descriptors.append(record)
        return path

    index_data = client.fetch(f"{REGISTRY}/manifests/v{version}")
    index_digest = "sha256:" + hashlib.sha256(index_data).hexdigest()
    index = json.loads(descriptor("index", index_digest).read_text())
    signature = verify_signature(client, root, index_digest, version, directory / "signature-verification.json")
    candidates = [m for m in index.get("manifests", []) if
                  m.get("platform", {}).get("os") == "linux" and m.get("platform", {}).get("architecture") == target.split("/")[1]]
    if len(candidates) != 1:
        fail("release index must contain exactly one selected architecture")
    selection = candidates[0]
    manifest = json.loads(descriptor("manifest", selection["digest"], selection["size"]).read_text())
    cfg = manifest["config"]
    image_config = json.loads(descriptor("config", cfg["digest"], cfg["size"]).read_text())
    if f"{image_config.get('os')}/{image_config.get('architecture')}" != target:
        fail("source image configuration platform mismatch")
    layers = [descriptor("layer", layer["digest"], layer["size"]) for layer in manifest["layers"]]
    selected = extract_payload(layers, target)
    archive = directory / "kaniko.tar.gz"
    write_payload(archive, selected)
    return {"version": version, "platform": target, "image": f"{REPOSITORY}:v{version}",
            "indexDigest": index_digest, "manifestDigest": selection["digest"],
            "configDigest": cfg["digest"], "sources": descriptors,
            "signature": signature, "archive": file_record(archive, root),
            "payloads": [{"path": name.removeprefix("kaniko/"), "sha256": hashlib.sha256(data).hexdigest(),
                          "size": len(data)} for name, data in sorted(selected.items())]}


def prefetch_kaniko(record, repo_root, *, offline=False):
    """Verify the locked graph; online mode may fetch missing immutable blobs."""
    root, client = Path(repo_root).resolve(), Registry()
    version, target = record.get("version"), record.get("platform")
    if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+", version) or target not in ("linux/amd64", "linux/arm64"):
        fail("frozen version/platform invalid")
    if record.get("image") != f"{REPOSITORY}:v{version}":
        fail("frozen image reference differs from selected version")
    evidence = json.loads(verified(record["signature"], root).read_text())
    identity = f"https://github.com/osscontainertools/kaniko/.github/workflows/images.yaml@refs/tags/v{version}"
    if (not re.fullmatch(r"v3\.\d+\.\d+", record["signature"].get("cosignVersion", ""))
        or evidence.get("cosign", {}).get("gitVersion") != record["signature"]["cosignVersion"]
        or record["signature"].get("identity") != identity or record["signature"].get("issuer") != ISSUER
        or evidence.get("identity") != identity or evidence.get("issuer") != ISSUER
        or evidence.get("image") != f"{REPOSITORY}@{record['indexDigest']}"
        or not any(s.get("critical", {}).get("image", {}).get("docker-manifest-digest") == record["indexDigest"]
                   for s in evidence.get("signatures", []))):
        fail("frozen signature evidence does not bind this release")
    source = {}
    layers = []
    for item in record["sources"]:
        if item.get("kind") not in ("index", "manifest", "config", "layer"):
            fail("unknown frozen source descriptor kind")
        digest = item.get("digest", "")
        if not DIGEST.fullmatch(digest) or item.get("sha256") != digest[7:]:
            fail("frozen OCI digest/hash disagreement")
        expected_url = f"{REGISTRY}/{'manifests' if item['kind'] in ('index', 'manifest') else 'blobs'}/{digest}"
        if item.get("url") != expected_url:
            fail("frozen source URL differs from immutable descriptor")
        path = checked_path(root, item["file"])
        if not path.exists() and not offline:
            client.cache(expected_url, path, item["sha256"])
        verified(item, root)
        if item["kind"] == "layer":
            layers.append(path)
        else:
            if item["kind"] in source:
                fail("duplicate source descriptor")
            source[item["kind"]] = (item, json.loads(path.read_text()))
    for kind, key in (("index", "indexDigest"), ("manifest", "manifestDigest"), ("config", "configDigest")):
        if kind not in source or source[kind][0]["digest"] != record[key]:
            fail("missing or incorrect immutable source descriptor")
    index, manifest, image_config = (source[k][1] for k in ("index", "manifest", "config"))
    selected = [m for m in index.get("manifests", []) if m.get("platform", {}).get("os") == "linux"
                and m.get("platform", {}).get("architecture") == target.split("/")[1]]
    if (len(selected) != 1 or selected[0]["digest"] != record["manifestDigest"]
        or selected[0]["size"] != source["manifest"][0]["size"]):
        fail("platform manifest does not belong to locked release index")
    if (manifest["config"]["digest"] != record["configDigest"]
        or manifest["config"]["size"] != source["config"][0]["size"]
        or f"{image_config.get('os')}/{image_config.get('architecture')}" != target):
        fail("locked source configuration/platform mismatch")
    layer_records = [i for i in record["sources"] if i["kind"] == "layer"]
    if [(i["digest"], i["size"]) for i in layer_records] != [(i["digest"], i["size"]) for i in manifest["layers"]]:
        fail("locked layers differ from source manifest")
    payload = extract_payload(layers, target)
    expected_payloads = [{"path": name.removeprefix("kaniko/"), "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
                         for name, data in sorted(payload.items())]
    if record["payloads"] != expected_payloads:
        fail("payload hashes differ from signed source image")
    archive = checked_path(root, record["archive"]["file"])
    if not archive.exists():
        write_payload(archive, payload)
    verified(record["archive"], root)
