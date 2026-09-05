"""Strict image naming settings and one selected profile."""

from __future__ import annotations

import json
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .hashing import sha256
from .process import run, run_json


REPO = Path(__file__).resolve().parents[2]
LOCK_LABEL = "devcontainer-blueprints.lock.sha256"
CONFIG_LABEL = "devcontainer-blueprints.config.sha256"
SETTINGS_LABEL = "devcontainer-blueprints.settings.sha256"
SETTINGS_KEYS = ("IMAGE_PREFIX", "IMAGE_FAMILY", "IMAGE_VERSION", "IMAGE_PROFILES")
PROFILE_PATTERN = re.compile(r"^[a-z][a-z0-9-]{0,31}$")
COMPONENT_PATTERN = re.compile(r"^[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*$")
TAG_PATTERN = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$")


class WorkflowError(Exception):
    pass


def fail(message: str) -> None:
    raise WorkflowError(message)


def read_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        fail(f"Expected a JSON object: {path}")
    return value


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


def artifact_root(repo: Path, value: str) -> Path:
    root = relative_path(repo, value)
    parts = root.relative_to(repo).parts
    if len(parts) != 2 or parts[0] != "artifacts":
        fail("Profile artifacts must be artifacts/<profile>.")
    return root


@dataclass(frozen=True)
class ImageSettings:
    prefix: str
    family: str
    version: str
    profiles: tuple[str, ...]
    path: Path
    digest: str

    def image(self, profile: str) -> str:
        if profile not in self.profiles:
            fail(f"Unknown profile: {profile}")
        return f"{self.prefix}/{self.family}-{profile}:{self.version}"


def load_settings(repo: Path = REPO) -> ImageSettings:
    path = repo.resolve() / "config/images.env"
    values: dict[str, str] = {}
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line or line.lstrip().startswith("#"):
            continue
        match = re.fullmatch(r"([A-Z][A-Z0-9_]*)=([^\r\n]*)", line)
        if not match:
            fail(f"config/images.env line {number} must be KEY=VALUE data")
        key, value = match.groups()
        if key not in SETTINGS_KEYS:
            fail(f"config/images.env line {number} has unknown key {key}")
        if key in values:
            fail(f"config/images.env line {number} duplicates {key}")
        if not value or value != value.strip() or re.search(r"[\s'\"`$\\;&|<>()[\]{}]", value):
            fail(f"config/images.env {key} contains shell syntax, quoting, interpolation, or whitespace")
        values[key] = value
    missing = [key for key in SETTINGS_KEYS if key not in values]
    if missing:
        fail(f"config/images.env is missing: {', '.join(missing)}")
    profiles = tuple(values["IMAGE_PROFILES"].split(","))
    prefix = values["IMAGE_PREFIX"]
    if (len(set(profiles)) != len(profiles) or not profiles
            or any(not PROFILE_PATTERN.fullmatch(profile) for profile in profiles)):
        fail("IMAGE_PROFILES must contain unique lowercase profile names")
    if (prefix.startswith("/") or prefix.endswith("/") or ":" in prefix or "@" in prefix
            or any(not COMPONENT_PATTERN.fullmatch(part) for part in prefix.split("/"))):
        fail("IMAGE_PREFIX is not a supported untagged OCI namespace")
    if not COMPONENT_PATTERN.fullmatch(values["IMAGE_FAMILY"]):
        fail("IMAGE_FAMILY is not a valid OCI repository component")
    if not TAG_PATTERN.fullmatch(values["IMAGE_VERSION"]):
        fail("IMAGE_VERSION is not a valid OCI tag")
    return ImageSettings(prefix, values["IMAGE_FAMILY"], values["IMAGE_VERSION"], profiles, path, sha256(path))


class Profile:
    def __init__(self, name: str, repo: Path = REPO):
        self.repo = repo.resolve()
        self.settings = load_settings(self.repo)
        if name not in self.settings.profiles:
            fail(f"Unknown profile {name!r}; expected one of {', '.join(self.settings.profiles)}")
        self.name = name
        self.config = self.repo / "config" / f"{name}.yaml"
        self.lock_path = self.repo / "config" / f"{name}.lock.json"
        self.lock = read_json(self.lock_path)
        if self.lock.get("schemaVersion") != 3:
            fail(f"A schemaVersion 3 lock is required for {name}; run update-lock.")
        config = self.lock.get("config", {})
        if config.get("profile") != name:
            fail("Lock profile differs from the selected profile.")
        self.image = self.settings.image(name)
        if self.lock.get("image", {}).get("reference") != self.image:
            fail("Lock image differs from config/images.env.")
        self.platform = self.lock["image"]["platform"]
        if self.platform not in {"linux/amd64", "linux/arm64"}:
            fail(f"Unsupported platform: {self.platform}")
        self.root = artifact_root(self.repo, config["artifacts"]["root"])
        if self.root != self.repo / "artifacts" / name:
            fail("Lock artifact root differs from the selected profile.")
        self.digest = sha256(self.lock_path)
        self.platform_root = self.root / self.platform.replace("/", "-")

    def verify(self, quiet: bool = False) -> None:
        run("bash", "-c", 'source "$1"; wolfi_verify_lock "$2" "$3" "$4"',
            "_", self.repo / "src/cli/common.sh", self.repo, self.config, self.lock_path,
            capture=quiet)
        if sha256(self.lock_path) != self.digest:
            fail("Profile lock changed during the operation.")

    def inspect(self, reference: str | None = None) -> dict[str, Any]:
        value = run_json("docker", "image", "inspect", reference or self.image)
        if not isinstance(value, list) or len(value) != 1:
            fail("Docker returned invalid image metadata.")
        image = value[0]
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", str(image.get("Id"))):
            fail("Docker returned an invalid immutable image ID.")
        if f"{image.get('Os')}/{image.get('Architecture')}" != self.platform:
            fail("Docker image platform differs from the profile lock.")
        if reference is None:
            labels = image.get("Config", {}).get("Labels") or {}
            expected = {
                LOCK_LABEL: self.digest,
                CONFIG_LABEL: self.lock["source"]["fileSha256"],
                SETTINGS_LABEL: self.settings.digest,
            }
            if any(labels.get(key) != value for key, value in expected.items()):
                fail("Output image has stale lock, profile, or naming labels; rebuild it.")
        return image

    def docker_list_size(self, expected_id: str) -> str:
        """Return Docker's user-facing image-list size for this exact image ID."""
        result = run(
            "docker", "image", "ls", "--no-trunc", "--format", "{{json .}}",
            self.image, capture=True,
        )
        records = [json.loads(line) for line in result.stdout.splitlines() if line]
        repository, tag = self.image.rsplit(":", 1)
        if (len(records) != 1 or records[0].get("Repository") != repository
                or records[0].get("Tag") != tag or records[0].get("ID") != expected_id):
            fail("Docker image listing differs from the selected immutable output.")
        size = records[0].get("Size")
        if not isinstance(size, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)?[kKMGT]?B", size):
            fail("Docker returned an invalid user-facing image size.")
        return size


class CleanSelection:
    """Cleanup can select derived paths before a lock exists."""

    def __init__(self, name: str, repo: Path = REPO):
        self.repo = repo.resolve()
        self.settings = load_settings(self.repo)
        if name not in self.settings.profiles:
            fail(f"Unknown profile: {name}")
        self.name = name
        self.config = self.repo / "config" / f"{name}.yaml"
        self.lock_path = self.repo / "config" / f"{name}.lock.json"
        self.image = self.settings.image(name)
        self.root = self.repo / "artifacts" / name
        value = run_json("node", self.repo / "src/config/config.mjs", "print-json", self.config)
        self.platform = value["image"]["platform"]
        self.config_digest = sha256(self.config)

    def verify(self, quiet: bool = False) -> None:
        if sha256(self.config) != self.config_digest or sha256(self.settings.path) != self.settings.digest:
            fail("Configuration changed during cleanup selection.")


def select_cleanup(name: str, repo: Path = REPO) -> Profile | CleanSelection:
    try:
        selected = Profile(name, repo)
        selected.verify(quiet=True)
        return selected
    except (WorkflowError, OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError):
        return CleanSelection(name, repo)
