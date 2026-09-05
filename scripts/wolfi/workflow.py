#!/usr/bin/env python3
"""Profile-scoped raw scans, verified offline bundles, and local cleanup."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


REPO = Path(__file__).resolve().parents[2]
LOCK_LABEL = "devcontainers.wolfi.lock.sha256"
SEVERITIES = ["UNKNOWN", "LOW", "MEDIUM", "HIGH", "CRITICAL"]


class WorkflowError(Exception):
    pass


def fail(message: str) -> None:
    raise WorkflowError(message)


def read_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        fail(f"Expected a JSON object: {path}")
    return value


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def timestamp() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def relative_path(root: Path, value: object) -> Path:
    if not isinstance(value, str) or not value or "\\" in value:
        fail(f"Invalid relative path: {value!r}")
    path = Path(value)
    if path.is_absolute() or any(part in {".", "..", ""} for part in value.split("/")):
        fail(f"Path must be normalized and repository-relative: {value}")
    result = root / path
    if result.is_symlink() or not result.resolve().is_relative_to(root.resolve()):
        fail(f"Path escapes its root or is a symlink: {value}")
    return result


def run(*args: str, capture: bool = False, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(args, check=check, text=True, capture_output=capture)


def artifact_root(repo: Path, value: str) -> Path:
    root = relative_path(repo, value)
    parts = root.relative_to(repo).parts
    if len(parts) < 2 or parts[0] != "artifacts":
        fail("Profile artifacts must occupy a dedicated directory below artifacts/.")
    return root


class Profile:
    def __init__(self, config: Path, lock: Path, repo: Path = REPO):
        self.repo = repo.resolve()
        self.config = config.resolve()
        self.lock_path = lock.resolve()
        self.lock = read_json(self.lock_path)
        if self.lock.get("schemaVersion") != 2:
            fail("A schemaVersion 2 Wolfi lock is required; refresh this profile's lock.")
        self.image = self.lock["image"]["reference"]
        self.platform = self.lock["image"]["platform"]
        if self.platform not in {"linux/amd64", "linux/arm64"}:
            fail(f"Unsupported platform: {self.platform}")
        self.root = artifact_root(self.repo, self.lock["config"]["artifacts"]["root"])
        self.digest = sha256(self.lock_path)
        self.platform_root = self.root / self.platform.replace("/", "-")

    def verify(self, quiet: bool = False) -> None:
        run("bash", "-c", 'source "$1"; wolfi_verify_lock "$2" "$3" "$4"',
            "_", str(self.repo / "scripts/wolfi/lib.sh"), str(self.repo),
            str(self.config), str(self.lock_path), capture=quiet)
        if sha256(self.lock_path) != self.digest:
            fail("Profile lock changed during the operation.")

    def inspect(self, reference: str | None = None) -> dict[str, Any]:
        value = json.loads(run("docker", "image", "inspect", reference or self.image,
                               capture=True).stdout)
        if not isinstance(value, list) or len(value) != 1:
            fail("Docker returned invalid image metadata.")
        image = value[0]
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", str(image.get("Id"))):
            fail("Docker returned an invalid immutable image ID.")
        if f"{image.get('Os')}/{image.get('Architecture')}" != self.platform:
            fail("Docker image platform differs from the profile lock.")
        if reference is None and (image.get("Config", {}).get("Labels") or {}).get(LOCK_LABEL) != self.digest:
            fail("Output image has a missing or stale complete-lock SHA256 label; rebuild it.")
        return image


class CleanSelection:
    """Cleanup can select partial artifacts before the first lock succeeds."""

    def __init__(self, config: Path, repo: Path = REPO):
        self.repo = repo.resolve()
        self.config = config.resolve()
        self.config_digest = sha256(self.config)
        value = json.loads(run("node", str(self.repo / "scripts/wolfi/config.mjs"),
                               "print-json", str(self.config), capture=True).stdout)
        self.image = value["image"]["reference"]
        self.platform = value["image"]["platform"]
        self.root = artifact_root(self.repo, value["artifacts"]["root"])

    def verify(self) -> None:
        if sha256(self.config) != self.config_digest:
            fail("Cleanup configuration changed during selection.")


def select_cleanup(config: Path, lock: Path, repo: Path = REPO) -> Profile | CleanSelection:
    try:
        profile = Profile(config, lock, repo)
        profile.verify(quiet=True)
        return profile
    except (WorkflowError, OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError):
        return CleanSelection(config, repo)


def extension_archive_skip(profile: Profile) -> list[str]:
    if not profile.lock["resolved"].get("extensions", {}).get("archive"):
        return []
    user = profile.lock["config"].get("user", {}).get("name", "root")
    home = "/root" if user == "root" else f"/home/{user}"
    return [f"{home}/vscode-extensions.tar.gz"]


def invalidate_report(output: Path) -> None:
    # Do this before lock/image validation: failure cannot leave a prior PASS current.
    for name in ("acceptance.json", "report.json", "report.md", "scan-metadata.json"):
        (output / name).unlink(missing_ok=True)
        (output / f"{name}.tmp").unlink(missing_ok=True)


def invalidate_unavailable_scan(args: argparse.Namespace, repo: Path = REPO) -> None:
    """A broken/missing lock must not preserve a prior canonical PASS."""
    outputs: set[Path] = set()
    if args.output_dir is not None:
        outputs.add(args.output_dir.resolve())
    else:
        # The old lock and current YAML may select different roots/platforms.
        # Neither source authorizes scanning; use them only to invalidate reports.
        try:
            lock = read_json(args.lock)
            root = artifact_root(repo, lock["config"]["artifacts"]["root"])
            platform = lock["image"]["platform"]
            if platform in {"linux/amd64", "linux/arm64"}:
                outputs.add(root / platform.replace("/", "-") / "reports/scan")
        except (WorkflowError, OSError, ValueError, KeyError, TypeError):
            pass
        try:
            selection = CleanSelection(args.config, repo)
            outputs.add(selection.root / selection.platform.replace("/", "-") / "reports/scan")
        except (WorkflowError, OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError):
            pass
    for output in outputs:
        invalidate_report(output)


def verify_scan(profile: Profile, output: Path) -> tuple[dict, dict, Counter]:
    metadata = read_json(output / "scan-metadata.json")
    if metadata.get("lockSha256") != profile.digest or metadata.get("images") != [profile.image]:
        fail("Scan image manifest or lock SHA256 differs from the current profile.")
    options = metadata.get("scannerOptions", {})
    expected = {"configFile": "/dev/null", "ambientTrivyEnvironmentCleared": True,
                "imageSource": "docker", "scanners": ["vuln"], "severities": SEVERITIES,
                "ignoreUnfixed": False, "ignoreFile": "/dev/null", "platform": profile.platform,
                "offlineScan": True, "skipDbUpdate": True, "skipJavaDbUpdate": True,
                "skipDirs": []}
    if any(options.get(key) != value for key, value in expected.items()):
        fail("Scan options do not describe a complete raw frozen scan.")
    permitted_skip = extension_archive_skip(profile)
    if options.get("skipFiles") not in ([], permitted_skip) or options.get("ignorePolicy", {}).get("applied") is not False:
        fail("Unexpected scan exclusions or ignore policy.")
    for database in ("vulnerability", "java"):
        if not (metadata.get("databaseIdentity", {}).get(database) or {}).get("updatedAt"):
            fail("Scan has no frozen database identity.")
    identities = metadata.get("imageIdentities", [])
    reports = metadata.get("reports", [])
    if len(identities) != 1 or len(reports) != 1:
        fail("Scan must contain exactly one image and report pair.")
    identity, record = identities[0], reports[0]
    if identity.get("reference") != profile.image or identity.get("platform") != profile.platform or record.get("image") != profile.image:
        fail("Report identity differs from the selected output.")
    report_path = relative_path(output, record["vulnerabilities"])
    sbom_path = relative_path(output, record["sbom"])
    if sha256(report_path) != record.get("vulnerabilitiesSha256") or sha256(sbom_path) != record.get("sbomSha256"):
        fail("Vulnerability report or SBOM bytes changed since scanning.")
    report, sbom = read_json(report_path), read_json(sbom_path)
    if report.get("ArtifactName") != profile.image or report.get("Metadata", {}).get("ImageID") != identity.get("imageId"):
        fail("Vulnerability report image identity is inconsistent.")
    component = sbom.get("metadata", {}).get("component", {})
    if (sbom.get("bomFormat") != "CycloneDX" or component.get("name") != profile.image
        or not any(p.get("name") == "aquasecurity:trivy:ImageID" and p.get("value") == identity.get("imageId") for p in component.get("properties", []))):
        fail("SBOM image identity is inconsistent.")
    counts: Counter = Counter()
    if not isinstance(report.get("Results"), list):
        fail("Invalid Trivy Results array.")
    for result in report["Results"]:
        if not isinstance(result, dict):
            fail("Invalid Trivy result object.")
        vulnerabilities = result.get("Vulnerabilities") or []
        if not isinstance(vulnerabilities, list):
            fail("Invalid Trivy vulnerability list.")
        for finding in vulnerabilities:
            if not isinstance(finding, dict):
                fail("Invalid Trivy vulnerability object.")
            severity = finding.get("Severity", "UNKNOWN")
            if severity not in SEVERITIES:
                fail(f"Unknown Trivy severity: {severity}")
            counts[severity] += 1
    return metadata, identity, counts


def scan(profile: Profile, args: argparse.Namespace) -> None:
    output = args.output_dir or profile.platform_root / "reports" / "scan"
    output = output.resolve()
    invalidate_report(output)
    profile.verify()
    identity = profile.inspect()
    cache = (args.cache_dir or profile.platform_root / "trivy-cache").resolve()
    environment = {key: value for key, value in os.environ.items() if not key.startswith("TRIVY_")}
    cache.mkdir(parents=True, exist_ok=True)
    common = ["--config", "/dev/null", "--cache-dir", str(cache), "--skip-version-check"]
    if not args.skip_db_download:
        for option in ("--download-db-only", "--download-java-db-only"):
            subprocess.run(["trivy", "image", *common, option], check=True, env=environment)
    version_cmd = ["trivy", "version", "--config", "/dev/null", "--cache-dir", str(cache), "--format", "json"]
    context = json.loads(subprocess.run(version_cmd, check=True, capture_output=True, text=True, env=environment).stdout)
    if not all(context.get(db, {}).get("UpdatedAt") for db in ("VulnerabilityDB", "JavaDB")):
        fail("Both Trivy databases are required; rerun without --skip-db-download online.")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".scan-", dir=output.parent) as directory:
        stage = Path(directory)
        command = [str(profile.repo / "scripts/scan-images-trivy.sh"), "--image", profile.image,
                   "--platform", profile.platform, "--output-dir", str(stage), "--cache-dir", str(cache),
                   "--no-ignore-policy", "--skip-db-update", "--skip-java-db-update", "--offline-scan"]
        if not args.include_vsix_archive:
            for archive in extension_archive_skip(profile):
                command += ["--skip-file", archive]
        subprocess.run(command, check=True, env=environment)
        metadata = read_json(stage / "scan-metadata.json")
        if metadata.get("trivy") != context:
            fail("Trivy version/database context changed during scanning.")
        metadata["lockSha256"] = profile.digest
        write_json(stage / "scan-metadata.json", metadata)
        metadata, scanned_identity, counts = verify_scan(profile, stage)
        profile.verify()
        if profile.inspect()["Id"] != identity["Id"] or scanned_identity["imageId"] != identity["Id"]:
            fail("Output image changed while scanning.")
        evaluated = not args.skip_acceptance_gate
        passed = not any(counts[severity] for severity in ("CRITICAL", "HIGH")) if evaluated else None
        acceptance = {"schemaVersion": 2, "generatedAt": timestamp(), "evaluated": evaluated,
                      "passed": passed, "image": profile.image, "imageId": identity["Id"],
                      "lockSha256": profile.digest, "policy": "No raw CRITICAL or HIGH findings",
                      "occurrences": {severity: counts[severity] for severity in SEVERITIES},
                      "reports": metadata["reports"]}
        write_json(stage / "acceptance.json", acceptance)
        archive_excluded = bool(metadata["scannerOptions"]["skipFiles"])
        report = {**acceptance, "sizeBytes": identity.get("Size"), "trivy": context,
                  "uninstalledVsixArchiveExcluded": archive_excluded,
                  "lowerSeveritiesRequireReview": True}
        browser_note = ""
        playwright = profile.lock["resolved"].get("playwright")
        if playwright:
            report["browserInventory"] = {
                "playwrightVersion": playwright["version"], "platform": playwright["platform"],
                "browsers": [{key: browser[key] for key in ("name", "revision", "browserVersion", "sha256")}
                             for browser in playwright["browsers"]],
                "advisoryCoverage": "Downloaded browser binary advisory coverage is not established by Trivy; raw zero findings is not proof of complete coverage."}
            browser_note = ("\nPlaywright " + playwright["version"] + ": "
                            + ", ".join(f"{b['name']} {b['browserVersion']} (revision {b['revision']})" for b in playwright["browsers"])
                            + ". Downloaded browser binary advisory coverage is not established by Trivy; "
                            "zero raw findings does not prove complete browser coverage.\n")
        write_json(stage / "report.json", report)
        status = "PASS" if passed else ("FAIL" if evaluated else "NOT EVALUATED")
        (stage / "report.md").write_text(
            f"# {profile.image}\n\nRaw Critical/High gate: **{status}**\n\n"
            f"Platform: `{profile.platform}`; image size: {identity.get('Size', 'unknown')} bytes.\n\n"
            + " | ".join(SEVERITIES) + "\n" + " | ".join("---" for _ in SEVERITIES) + "\n"
            + " | ".join(str(counts[s]) for s in SEVERITIES)
            + "\n\nLower-severity findings require review.\n"
            + ("The uninstalled VSIX transfer archive was excluded.\n" if archive_excluded else "No image paths were excluded.\n")
            + browser_note,
            encoding="utf-8")
        output.mkdir(parents=True, exist_ok=True)
        for source in stage.iterdir():
            source.replace(output / source.name)
    print(f"Raw scan {status}: {output / 'report.md'}")
    if evaluated and not passed:
        fail(f"Vulnerability gate failed: {counts['CRITICAL']} Critical and {counts['HIGH']} High occurrences.")


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
        if identity["Id"] not in archive_identity(temporary_tar, profile.image, profile.platform, {LOCK_LABEL: profile.digest}):
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
    for path in (profile.config, profile.lock_path, image_tar):
        files[str(path.relative_to(profile.repo))] = sha256(path)
    manifest = {"schemaVersion": 2, "generatedAt": timestamp(), "image": profile.image,
                "platform": profile.platform, "imageId": identity["Id"], "lockSha256": profile.digest,
                "config": str(profile.config.relative_to(profile.repo)),
                "lock": str(profile.lock_path.relative_to(profile.repo)),
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
    expected = {"schemaVersion": 2, "image": profile.image, "platform": profile.platform,
                "lockSha256": profile.digest, "config": str(profile.config.relative_to(profile.repo)),
                "lock": str(profile.lock_path.relative_to(profile.repo))}
    if any(manifest.get(key) != value for key, value in expected.items()):
        fail("Transfer manifest differs from the selected profile/lock/platform.")
    files = manifest.get("files")
    if not isinstance(files, dict):
        fail("Transfer manifest must list exact file hashes.")
    locked = locked_files(profile)
    for name, digest in locked.items():
        if files.get(name) != digest:
            fail(f"Transfer manifest omits or alters a locked artifact: {name}")
    for path in (profile.config, profile.lock_path):
        if files.get(str(path.relative_to(profile.repo))) != sha256(path):
            fail("Transfer config or lock bytes differ from the local selected profile.")
    image_tar = relative_path(profile.repo, manifest["imageTar"])
    if image_tar != profile.root / "transfer" / "image.tar" or manifest["imageTar"] not in files:
        fail("Transfer manifest does not identify this profile's saved output image.")
    verify_files(profile.repo, files)
    output_ids = archive_identity(image_tar, profile.image, profile.platform, {LOCK_LABEL: profile.digest})
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


def clean(profile: Profile | CleanSelection, args: argparse.Namespace) -> None:
    profile.verify()
    targets = [profile.root]
    bundle = profile.repo / f"artifacts-{profile.config.stem}-{profile.platform.replace('/', '-')}.tar.gz"
    targets.extend([bundle, bundle.with_name(bundle.name + ".sha256")])
    for target in targets:
        if target.exists():
            print(f"{'Would remove' if args.dry_run else 'Removing'}: {target}")
            if not args.dry_run:
                if target.is_dir():
                    shutil.rmtree(target)
                else:
                    target.unlink()
    if args.docker_images:
        result = run("docker", "image", "inspect", profile.image, capture=True, check=False)
        if result.returncode == 0:
            print(f"{'Would remove' if args.dry_run else 'Removing'} image: {profile.image}")
            if not args.dry_run:
                removed = run("docker", "image", "rm", profile.image, check=False)
                if removed.returncode:
                    print("Retained image because Docker could not remove it.", file=sys.stderr)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("scan", "package", "load", "clean"):
        subparser = subparsers.add_parser(command)
        subparser.add_argument("--config", required=True, type=Path)
        subparser.add_argument("--lock", required=True, type=Path)
        if command == "scan":
            subparser.add_argument("--output-dir", type=Path)
            subparser.add_argument("--cache-dir", type=Path)
            subparser.add_argument("--skip-db-download", action="store_true")
            subparser.add_argument("--skip-acceptance-gate", action="store_true")
            subparser.add_argument("--include-vsix-archive", action="store_true")
        elif command == "package":
            subparser.add_argument("--output", type=Path)
        elif command == "clean":
            subparser.add_argument("--docker-images", action="store_true")
            subparser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    try:
        try:
            profile = (select_cleanup(args.config, args.lock) if args.command == "clean"
                       else Profile(args.config, args.lock))
        except (WorkflowError, OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError):
            if args.command == "scan":
                invalidate_unavailable_scan(args)
            raise
        {"scan": scan, "package": package, "load": load, "clean": clean}[args.command](profile, args)
    except (WorkflowError, OSError, ValueError, KeyError, TypeError, tarfile.TarError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"ERROR: {error}") from error


if __name__ == "__main__":
    main()
