#!/usr/bin/env python3
"""Shared validation and hashing helpers for the frozen Wolfi artifact supply."""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any, Iterable


ARCHITECTURES = {
    "linux/amd64": "x86_64",
    "linux/arm64": "aarch64",
}
SHA256_RE = re.compile(r"^[a-f0-9]{64}$")
OCI_DIGEST_RE = re.compile(r"^sha256:[a-f0-9]{64}$")
PACKAGE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9+_.@~-]*$")
MODULE_RE = re.compile(r"^[a-z][a-z0-9-]*$")


class SupplyError(RuntimeError):
    """Raised when an artifact or its immutable metadata is invalid."""


class HTTPSRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Reject a downgrade before urllib sends the redirected request."""

    def redirect_request(self, request, response, code, message, headers, new_url):
        if urllib.parse.urlsplit(new_url).scheme != "https":
            raise SupplyError(f"artifact redirected to non-HTTPS: {new_url}")
        return super().redirect_request(request, response, code, message, headers, new_url)


def run(
    command: list[str],
    *,
    check: bool = True,
    capture_output: bool = False,
    text: bool = True,
) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            command,
            check=check,
            capture_output=capture_output,
            text=text,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        detail = ""
        if isinstance(error, subprocess.CalledProcessError):
            detail = (error.stderr or error.stdout or "").strip()
        suffix = f": {detail}" if detail else ""
        raise SupplyError(f"command failed: {' '.join(command)}{suffix}") from error


def load_json(path: Path, description: str) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SupplyError(f"unable to read {description} {path}: {error}") from error


def write_json_atomic(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        temporary.write_text(
            json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        raise SupplyError(f"unable to hash {path}: {error}") from error
    return digest.hexdigest()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def canonical_json_sha256(value: Any) -> str:
    serialized = json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    )
    return hashlib.sha256(serialized.encode("utf-8")).hexdigest()


def require_sha256(value: Any, location: str) -> str:
    if not isinstance(value, str) or not SHA256_RE.fullmatch(value):
        raise SupplyError(f"{location} must be a lowercase SHA256 value")
    return value


def require_oci_digest(value: Any, location: str) -> str:
    if not isinstance(value, str) or not OCI_DIGEST_RE.fullmatch(value):
        raise SupplyError(f"{location} must be an OCI SHA256 digest")
    return value


def require_platform(value: Any) -> tuple[str, str]:
    if value not in ARCHITECTURES:
        raise SupplyError(
            f"unsupported platform {value!r}; expected one of {', '.join(ARCHITECTURES)}"
        )
    return value, ARCHITECTURES[value]


def platform_key(platform: str) -> str:
    require_platform(platform)
    return platform.replace("/", "-")


def require_relative_path(value: Any, location: str) -> Path:
    if not isinstance(value, str) or not value or "\\" in value:
        raise SupplyError(f"{location} must be a relative POSIX path")
    candidate = Path(value)
    if candidate.is_absolute() or any(part in {"", ".", ".."} for part in candidate.parts):
        raise SupplyError(f"{location} must be a safe relative POSIX path")
    if candidate.as_posix() != value:
        raise SupplyError(f"{location} must be a normalized relative POSIX path")
    return candidate


def path_beneath(root: Path, relative: Any, location: str) -> Path:
    safe_relative = require_relative_path(relative, location)
    root_resolved = root.resolve()
    candidate = (root_resolved / safe_relative).resolve()
    if candidate != root_resolved and root_resolved not in candidate.parents:
        raise SupplyError(f"{location} escapes the artifact root")
    return candidate


def validate_https_repository(name: str, value: Any) -> str:
    if not isinstance(value, str) or not value or value.endswith("/"):
        raise SupplyError(f"{name} repository must be a canonical HTTPS URL")
    parsed = urllib.parse.urlsplit(value)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
        or parsed.path in {"", "/"}
    ):
        raise SupplyError(f"{name} repository must be a plain HTTPS URL")
    canonical = urllib.parse.urlunsplit(parsed)
    if canonical != value or "/../" in f"{parsed.path}/" or "/./" in f"{parsed.path}/":
        raise SupplyError(f"{name} repository URL is not canonical")
    return value


def validate_pinned_image(reference: Any, digest: Any | None = None) -> tuple[str, str]:
    if not isinstance(reference, str) or reference.count("@") != 1:
        raise SupplyError("base image must be a digest-pinned OCI reference")
    repository, reference_digest = reference.rsplit("@", 1)
    require_oci_digest(reference_digest, "base image digest")
    if not repository or any(character.isspace() for character in repository):
        raise SupplyError("base image repository is invalid")
    if digest is not None and require_oci_digest(digest, "expected base digest") != reference_digest:
        raise SupplyError("base image reference and expected digest do not match")
    return repository, reference_digest


def ensure_empty_directory(path: Path, description: str) -> None:
    if path.exists():
        if not path.is_dir():
            raise SupplyError(f"{description} is not a directory: {path}")
        try:
            next(path.iterdir())
        except StopIteration:
            return
        raise SupplyError(
            f"{description} is not empty: {path}; use a clean platform artifact directory"
        )
    path.mkdir(parents=True)


def download(
    url: str,
    destination: Path,
    *,
    expected_sha256: str | None = None,
) -> tuple[str, bool]:
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise SupplyError(f"artifact URL must use HTTPS without credentials: {url}")
    if expected_sha256 is not None:
        require_sha256(expected_sha256, f"expected hash for {destination}")
        if destination.is_file() and sha256_file(destination) == expected_sha256:
            return expected_sha256, True

    destination.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(
        url, headers={"User-Agent": "devcontainer-blueprints-wolfi-lock/1"}
    )
    opener = urllib.request.build_opener(HTTPSRedirectHandler())
    last_error: OSError | urllib.error.URLError | None = None
    for attempt in range(5):
        temporary = destination.with_name(
            f".{destination.name}.{uuid.uuid4().hex}.tmp"
        )
        try:
            with opener.open(request, timeout=180) as response, temporary.open(
                "wb"
            ) as output:
                if response.geturl() != url:
                    redirected = urllib.parse.urlsplit(response.geturl())
                    if redirected.scheme != "https":
                        raise SupplyError(
                            f"artifact download redirected away from HTTPS: {url}"
                        )
                downloaded_size = 0
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    output.write(chunk)
                    downloaded_size += len(chunk)
                declared_size = response.headers.get("Content-Length")
                if declared_size is not None:
                    try:
                        expected_size = int(declared_size)
                    except ValueError as error:
                        raise SupplyError(
                            f"artifact server returned an invalid Content-Length: {url}"
                        ) from error
                    if downloaded_size != expected_size:
                        raise OSError(
                            f"truncated response: expected {expected_size} bytes, "
                            f"received {downloaded_size}"
                        )
            actual = sha256_file(temporary)
            if expected_sha256 is not None and actual != expected_sha256:
                raise SupplyError(
                    f"checksum mismatch for {url}: expected {expected_sha256}, got {actual}"
                )
            os.replace(temporary, destination)
            return actual, False
        except (OSError, urllib.error.URLError) as error:
            if isinstance(error, urllib.error.HTTPError) and error.code not in (
                408, 429, 500, 502, 503, 504,
            ):
                raise SupplyError(f"download rejected: {url}: {error}") from error
            last_error = error
            if attempt == 4:
                break
            delay = 2**attempt
            print(
                f"Retrying {url} after transient download error ({attempt + 1}/5): "
                f"{error}",
                file=sys.stderr,
            )
            time.sleep(delay)
        finally:
            temporary.unlink(missing_ok=True)
    raise SupplyError(f"unable to download {url}: {last_error}") from last_error


def parse_pkginfo(path: Path) -> dict[str, Any]:
    try:
        with tarfile.open(path, mode="r:gz") as archive:
            member = archive.getmember(".PKGINFO")
            source = archive.extractfile(member)
            if source is None:
                raise KeyError(".PKGINFO")
            content = source.read().decode("utf-8")
    except (OSError, EOFError, tarfile.TarError, KeyError, UnicodeDecodeError) as error:
        raise SupplyError(f"unable to read .PKGINFO from {path}: {error}") from error

    metadata: dict[str, Any] = {"provides": []}
    for line in content.splitlines():
        if " = " not in line:
            continue
        key, value = line.split(" = ", 1)
        if key == "provides":
            metadata["provides"].append(value)
        else:
            metadata.setdefault(key, value)
    for key in ("pkgname", "pkgver", "arch"):
        if not metadata.get(key):
            raise SupplyError(f"{path} .PKGINFO is missing {key}")
    return metadata


def index_signature_key_names(path: Path) -> list[str]:
    prefix = ".SIGN."
    try:
        with tarfile.open(path, mode="r:gz") as archive:
            names = [member.name for member in archive.getmembers()]
    except (OSError, tarfile.TarError) as error:
        raise SupplyError(f"unable to inspect signed APK index {path}: {error}") from error

    signatures = sorted(name for name in names if name.startswith(prefix))
    if not signatures or "APKINDEX" not in names:
        raise SupplyError(f"APK index does not contain signatures and APKINDEX: {path}")

    key_names: list[str] = []
    for signature in signatures:
        parts = signature.split(".", 3)
        if len(parts) != 4 or not parts[3].endswith(".rsa.pub"):
            raise SupplyError(f"unsupported APK index signature name: {signature}")
        key_names.append(parts[3])
    return sorted(set(key_names))


def parse_apkindex(path: Path) -> list[dict[str, str]]:
    """Return package identities from a signed APKINDEX archive."""
    try:
        with tarfile.open(path, mode="r:gz") as archive:
            source = archive.extractfile("APKINDEX")
            if source is None:
                raise KeyError("APKINDEX")
            content = source.read().decode("utf-8")
    except (OSError, tarfile.TarError, KeyError, UnicodeDecodeError) as error:
        raise SupplyError(f"unable to read APKINDEX from {path}: {error}") from error

    packages: list[dict[str, str]] = []
    for block in content.split("\n\n"):
        fields: dict[str, str] = {}
        for line in block.splitlines():
            if len(line) >= 2 and line[1] == ":":
                fields.setdefault(line[0], line[2:])
        if not fields:
            continue
        try:
            name = fields["P"]
            version = fields["V"]
            architecture = fields["A"]
        except KeyError as error:
            raise SupplyError(
                f"APKINDEX record in {path} is missing {error.args[0]}"
            ) from error
        if not PACKAGE_RE.fullmatch(name):
            raise SupplyError(f"APKINDEX contains an unsafe package name: {name!r}")
        if not version or "/" in version or version in {".", ".."}:
            raise SupplyError(
                f"APKINDEX contains an unsafe version for {name}: {version!r}"
            )
        packages.append(
            {"name": name, "version": version, "architecture": architecture}
        )
    if not packages:
        raise SupplyError(f"APKINDEX contains no package records: {path}")
    return packages


def exact_version_matches(selector: str, package_version: str) -> bool:
    if selector == "latest":
        return True
    return package_version == selector or any(
        package_version.startswith(f"{selector}{separator}")
        for separator in (".", "-", "_", "+")
    )


def get_config_path(config: Any, dot_path: str) -> tuple[bool, Any]:
    current = config
    for component in dot_path.split("."):
        if not isinstance(current, dict) or component not in current:
            return False, None
        current = current[component]
    return True, current


def load_package_mapping(path: Path) -> dict[str, Any]:
    value = load_json(path, "package-root mapping")
    if not isinstance(value, dict) or set(value) - {"utilityCatalog"} != {
        "schemaVersion",
        "packages",
        "packageSets",
    }:
        raise SupplyError("package-root mapping has unexpected top-level fields")
    if value["schemaVersion"] != 1:
        raise SupplyError("package-root mapping schemaVersion must be 1")
    if not isinstance(value["packages"], list) or not value["packages"]:
        raise SupplyError("package-root mapping packages must be a non-empty array")
    if not isinstance(value["packageSets"], dict) or not value["packageSets"]:
        raise SupplyError("package-root mapping packageSets must be a non-empty mapping")
    if "utilityCatalog" in value:
        catalog = load_json(path.parent / value["utilityCatalog"], "reviewed utility catalog")
        for key, utility in catalog.items():
            for package in utility["packages"]:
                value["packages"].append({"module": "utilities", "configPath": f"utilities.{key}", **package})
    return value


def expand_package_roots(
    config: dict[str, Any], mapping: dict[str, Any]
) -> tuple[list[dict[str, Any]], dict[str, list[str]]]:
    roots: list[dict[str, Any]] = []
    seen_roots: set[tuple[str, str]] = set()
    known_modules: set[str] = set()

    for index, entry in enumerate(mapping["packages"]):
        location = f"package mapping packages[{index}]"
        if not isinstance(entry, dict):
            raise SupplyError(f"{location} must be an object")
        allowed = {
            "module",
            "name",
            "nameTemplate",
            "repository",
            "configPath",
            "unlessConfigPath",
            "each",
            "validateSelector",
        }
        unknown = set(entry) - allowed
        if unknown:
            raise SupplyError(f"{location} has unknown fields: {', '.join(sorted(unknown))}")
        module = entry.get("module")
        repository = entry.get("repository")
        if not isinstance(module, str) or not MODULE_RE.fullmatch(module):
            raise SupplyError(f"{location}.module is invalid")
        if repository not in {"main", "extra"}:
            raise SupplyError(f"{location}.repository must be main or extra")
        if ("name" in entry) == ("nameTemplate" in entry):
            raise SupplyError(f"{location} must define exactly one of name or nameTemplate")
        known_modules.add(module)

        excluded_path = entry.get("unlessConfigPath")
        if excluded_path is not None:
            if not isinstance(excluded_path, str) or not excluded_path:
                raise SupplyError(f"{location}.unlessConfigPath is invalid")
            present, configured = get_config_path(config, excluded_path)
            if present and configured is not False:
                continue

        config_path = entry.get("configPath")
        if config_path is None:
            selectors: list[Any] = ["latest"]
        else:
            if not isinstance(config_path, str) or not config_path:
                raise SupplyError(f"{location}.configPath is invalid")
            present, configured = get_config_path(config, config_path)
            if not present or configured is False:
                continue
            if entry.get("each", False):
                if not isinstance(configured, list) or not configured:
                    raise SupplyError(f"{config_path} must be a non-empty array")
                selectors = configured
            elif isinstance(configured, str):
                selectors = [configured]
            else:
                selectors = ["latest"]

        for selector_value in selectors:
            if not isinstance(selector_value, str) or not selector_value:
                raise SupplyError(f"{location} resolved a non-string selector")
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,127}", selector_value):
                raise SupplyError(f"{location} resolved an unsafe selector: {selector_value}")
            package_name = entry.get("name")
            if package_name is None:
                package_name = entry["nameTemplate"].replace(
                    "{selector}", selector_value
                )
            if not isinstance(package_name, str) or not PACKAGE_RE.fullmatch(package_name):
                raise SupplyError(f"{location} resolved an invalid package name")
            key = (module, package_name)
            if key in seen_roots:
                raise SupplyError(f"duplicate root in module {module}: {package_name}")
            seen_roots.add(key)
            roots.append(
                {
                    "module": module,
                    "name": package_name,
                    "repository": repository,
                    "selector": selector_value,
                    "validateSelector": entry.get("validateSelector", True),
                }
            )

    package_sets: dict[str, list[str]] = {}
    for set_name, modules in mapping["packageSets"].items():
        if not isinstance(set_name, str) or not MODULE_RE.fullmatch(set_name):
            raise SupplyError(f"invalid package-set name: {set_name!r}")
        if (
            not isinstance(modules, list)
            or not modules
            or any(not isinstance(module, str) for module in modules)
        ):
            raise SupplyError(f"package set {set_name} must list modules")
        unknown_modules = set(modules) - known_modules
        if unknown_modules:
            raise SupplyError(
                f"package set {set_name} references unknown modules: "
                f"{', '.join(sorted(unknown_modules))}"
            )
        enabled_modules = {
            root["module"] for root in roots if root["module"] in modules
        }
        if enabled_modules:
            package_sets[set_name] = [module for module in dict.fromkeys(modules) if module in enabled_modules]

    return sorted(roots, key=lambda item: (item["module"], item["name"])), package_sets


def roots_for_modules(
    roots: Iterable[dict[str, Any]], modules: Iterable[str]
) -> list[dict[str, Any]]:
    selected_modules = set(modules)
    by_name: dict[str, dict[str, Any]] = {}
    for root in roots:
        if root["module"] not in selected_modules:
            continue
        existing = by_name.get(root["name"])
        if existing is not None and existing["repository"] != root["repository"]:
            raise SupplyError(
                f"package {root['name']} maps to conflicting repositories in one set"
            )
        if existing is not None:
            # A transitive component root may share a reviewed utility. Keep an
            # explicit version constraint instead of losing it to iteration order.
            constraints = {r["selector"] for r in (existing, root)
                           if r.get("validateSelector", True) and r["selector"] != "latest"}
            if len(constraints) > 1:
                raise SupplyError(f"package {root['name']} maps to conflicting selectors in one set")
            if existing["selector"] in constraints:
                continue
        by_name[root["name"]] = root
    return [by_name[name] for name in sorted(by_name)]


def validate_selected_package_set(config: dict[str, Any], package_sets: Any) -> None:
    """Reject stale or extra package roots even when artifact bytes are valid."""
    if not isinstance(package_sets, dict) or set(package_sets) != {"final"}:
        raise SupplyError("Wolfi lock must contain exactly the selected final APK package set")
    mapping = load_package_mapping(Path(__file__).resolve().parent / "package-roots.json")
    roots, enabled_sets = expand_package_roots(config, mapping)
    selected_roots = roots_for_modules(roots, enabled_sets["final"])
    final = package_sets["final"]
    if not isinstance(final, dict) or final.get("modules") != enabled_sets["final"]:
        raise SupplyError("final APK modules differ from the configured selection")
    locked_roots = final.get("roots")
    if not isinstance(locked_roots, list) or any(not isinstance(root, dict) for root in locked_roots):
        raise SupplyError("final APK roots must be an array of records")
    expected = [(root["module"], root["name"], root["repository"], root["selector"]) for root in selected_roots]
    actual = [(root.get("module"), root.get("requestedName"), root.get("repository"), root.get("requestedSelector")) for root in locked_roots]
    if actual != expected:
        raise SupplyError("final APK roots differ from the configured selection")
