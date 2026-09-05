#!/usr/bin/env python3
"""Install the selected final APK closure from signed local repositories."""

from __future__ import annotations

import argparse
import json
import re
import shlex
import tempfile
import uuid
from pathlib import Path
from typing import Any

from supply_lib import (
    SupplyError,
    load_json,
    path_beneath,
    platform_key,
    require_platform,
    require_sha256,
    run,
)


PACKAGE_SET_RE = re.compile(r"^[a-z][a-z0-9-]*$")
TESTED_PACKAGE_SETS = ("final",)


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


def shell_join(values: list[str]) -> str:
    return " ".join(shlex.quote(value) for value in values)


def build_test_script(
    *,
    apk: dict[str, Any],
    packages_by_id: dict[str, dict[str, Any]],
    architecture: str,
) -> tuple[str, dict[str, set[str]]]:
    package_sets = require_mapping(apk.get("packageSets"), "resolved.apk.packageSets")
    repositories = require_mapping(apk.get("repositories"), "resolved.apk.repositories")
    lines = [
        "set -eux",
        "mkdir -p /work/results /work/repos /work/roots",
        "apk info -v | sort > /work/results/base.installed",
    ]
    expected_installed: dict[str, set[str]] = {}

    for set_name in TESTED_PACKAGE_SETS:
        if not PACKAGE_SET_RE.fullmatch(set_name) or set_name not in package_sets:
            raise SupplyError(f"required offline test package set is missing: {set_name}")
        package_set = require_mapping(package_sets[set_name], f"packageSets.{set_name}")
        closure = require_array(package_set.get("closure"), f"packageSets.{set_name}.closure")
        constraints = require_array(
            package_set.get("packages"), f"packageSets.{set_name}.packages"
        )
        if not closure or not constraints or any(not isinstance(x, str) for x in constraints):
            raise SupplyError(f"package set {set_name} has no locked closure/roots")

        set_repo_root = f"/work/repos/{set_name}"
        root = f"/work/roots/{set_name}"
        closure_records: list[dict[str, Any]] = []
        for package_id in closure:
            if not isinstance(package_id, str) or package_id not in packages_by_id:
                raise SupplyError(f"package set {set_name} has an unknown closure member")
            closure_records.append(packages_by_id[package_id])
        used_repositories = sorted({record["repository"] for record in closure_records})
        expected_installed[set_name] = {
            f"{record['name']}-{record['version']}" for record in closure_records
        }

        lines.append(
            "mkdir -p "
            + shell_join(
                [
                    f"{set_repo_root}/repositories/{repository}/{architecture}"
                    for repository in used_repositories
                ]
                + [
                    f"{root}/etc/apk",
                    f"{root}/lib/apk/db",
                    f"{root}/var/cache/apk",
                    f"{root}/dev",
                ]
            )
        )
        lines.append(
            f"cp /etc/apk/world {shlex.quote(root + '/etc/apk/world')}"
        )
        lines.append(
            f"cp /lib/apk/db/installed {shlex.quote(root + '/lib/apk/db/installed')}"
        )
        lines.append(
            "touch "
            + shell_join(
                [
                    f"{root}/lib/apk/db/scripts.tar",
                    f"{root}/lib/apk/db/triggers",
                    f"{root}/dev/null",
                ]
            )
        )
        for repository in used_repositories:
            record = require_mapping(
                repositories.get(repository), f"repositories.{repository}"
            )
            index_file = path_beneath(
                Path("/artifacts"), record.get("indexFile"), "locked index file"
            ).as_posix()
            destination = (
                f"{set_repo_root}/repositories/{repository}/{architecture}/APKINDEX.tar.gz"
            )
            lines.append(f"ln -s {shlex.quote(index_file)} {shlex.quote(destination)}")
        for record in closure_records:
            package_file = path_beneath(
                Path("/artifacts"), record.get("file"), "locked package file"
            ).as_posix()
            destination = (
                f"{set_repo_root}/repositories/{record['repository']}/{architecture}/"
                f"{Path(record['file']).name}"
            )
            lines.append(f"ln -s {shlex.quote(package_file)} {shlex.quote(destination)}")
        repository_urls = [
            f"file://{set_repo_root}/repositories/{repository}"
            for repository in used_repositories
        ]
        lines.append(
            f"printf '%s\\n' {shell_join(repository_urls)} > "
            f"{shlex.quote(set_repo_root + '/repositories.list')}"
        )
        lines.append(
            f"apk --root {shlex.quote(root)} --no-network --no-scripts "
            "--keys-dir /artifacts/keys "
            f"--repositories-file {shlex.quote(set_repo_root + '/repositories.list')} "
            f"add {shell_join(constraints)}"
        )
        lines.append(
            f"apk --root {shlex.quote(root)} info -v | sort > "
            f"/work/results/{shlex.quote(set_name)}.installed"
        )
    return "\n".join(lines) + "\n", expected_installed


def run_offline_install(
    *, apk_root: Path, local_base: str, platform: str, script: str
) -> dict[str, set[str]]:
    container_name = f"wolfi-offline-install-{uuid.uuid4().hex[:12]}"
    with tempfile.TemporaryDirectory(prefix="wolfi-offline-install-") as temporary_name:
        temporary_root = Path(temporary_name)
        script_path = temporary_root / "test.sh"
        script_path.write_text(script, encoding="utf-8")
        results = temporary_root / "results"
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
                    "/test.sh",
                ],
                capture_output=True,
            )
            run(
                ["docker", "cp", f"{apk_root.resolve()}/.", f"{container_name}:/artifacts"],
                capture_output=True,
            )
            run(
                ["docker", "cp", str(script_path), f"{container_name}:/test.sh"],
                capture_output=True,
            )
            result = run(
                ["docker", "start", "--attach", container_name],
                check=False,
                capture_output=True,
            )
            if result.returncode == 0:
                run(
                    ["docker", "cp", f"{container_name}:/work/results", str(results)],
                    capture_output=True,
                )
            if result.returncode != 0:
                state = run(
                    [
                        "docker",
                        "container",
                        "inspect",
                        container_name,
                        "--format",
                        "{{json .State}}",
                    ],
                    check=False,
                    capture_output=True,
                )
                result.stderr = "\n".join(
                    part for part in (result.stderr, state.stdout, state.stderr) if part
                )
        finally:
            run(
                ["docker", "container", "rm", "--force", container_name],
                check=False,
                capture_output=True,
            )
        if result is None or result.returncode != 0:
            detail = "" if result is None else "\n".join(
                part.strip() for part in (result.stderr, result.stdout) if part.strip()
            )
            raise SupplyError(f"offline signed APK installation failed: {detail}")
        try:
            base_installed = set(
                (results / "base.installed").read_text(encoding="utf-8").splitlines()
            )
        except OSError as error:
            raise SupplyError("offline install omitted base package results") from error
        installed: dict[str, set[str]] = {"base": base_installed}
        for set_name in TESTED_PACKAGE_SETS:
            path = results / f"{set_name}.installed"
            try:
                installed[set_name] = set(path.read_text(encoding="utf-8").splitlines())
            except OSError as error:
                raise SupplyError(f"offline install omitted results for {set_name}: {error}") from error
        return installed


def main() -> None:
    args = parse_args()
    try:
        expected_hash = require_sha256(args.config_sha256, "config SHA256")
        lock = load_json(args.lock.resolve(), "Wolfi lock")
        if not isinstance(lock, dict):
            raise SupplyError("Wolfi lock must be an object")
        source = require_mapping(lock.get("source"), "lock.source")
        if source.get("semanticSha256") != expected_hash:
            raise SupplyError("lock semantic hash does not match --config-sha256")
        config = require_mapping(lock.get("config"), "lock.config")
        platform, architecture = require_platform(
            require_mapping(config.get("image"), "lock.config.image").get("platform")
        )
        apk = require_mapping(
            require_mapping(lock.get("resolved"), "lock.resolved").get("apk"),
            "lock.resolved.apk",
        )
        slug = platform_key(platform)
        apk_root = args.artifact_root.resolve() / slug / "apk"
        packages = require_array(apk.get("packages"), "resolved.apk.packages")
        packages_by_id: dict[str, dict[str, Any]] = {}
        for index, raw_record in enumerate(packages):
            record = require_mapping(raw_record, f"packages[{index}]")
            package_id = record.get("id")
            if not isinstance(package_id, str) or package_id in packages_by_id:
                raise SupplyError("locked APK package IDs are invalid or duplicated")
            packages_by_id[package_id] = record
        artifact = require_mapping(
            require_mapping(apk.get("baseImage"), "resolved.apk.baseImage").get("artifact"),
            "resolved.apk.baseImage.artifact",
        )
        local_base = artifact.get("localReference")
        if not isinstance(local_base, str) or not local_base:
            raise SupplyError("locked local base reference is missing")
        package_sets = require_mapping(apk.get("packageSets"), "resolved.apk.packageSets")
        covered_ids: set[str] = set()
        for set_name in TESTED_PACKAGE_SETS:
            package_set = require_mapping(
                package_sets.get(set_name), f"resolved.apk.packageSets.{set_name}"
            )
            covered_ids.update(
                require_array(
                    package_set.get("closure"),
                    f"resolved.apk.packageSets.{set_name}.closure",
                )
            )
        if covered_ids != set(packages_by_id):
            uncovered = sorted(set(packages_by_id) - covered_ids)
            unknown = sorted(covered_ids - set(packages_by_id))
            raise SupplyError(
                "offline install package-set coverage mismatch; "
                f"uncovered={uncovered}, unknown={unknown}"
            )
        script, expected = build_test_script(
            apk=apk,
            packages_by_id=packages_by_id,
            architecture=architecture,
        )
        installed = run_offline_install(
            apk_root=apk_root,
            local_base=local_base,
            platform=platform,
            script=script,
        )
        base_installed = installed["base"]
        for set_name in TESTED_PACKAGE_SETS:
            expected_with_base = expected[set_name] | base_installed
            if installed[set_name] != expected_with_base:
                missing = sorted(expected_with_base - installed[set_name])
                unexpected = sorted(installed[set_name] - expected_with_base)
                raise SupplyError(
                    f"offline {set_name} closure mismatch; missing={missing}, "
                    f"unexpected={unexpected}"
                )
            print(
                f"Offline signed install passed for {set_name}: "
                f"{len(installed[set_name])} exact packages."
            )
    except SupplyError as error:
        raise SystemExit(f"ERROR: {error}") from error


if __name__ == "__main__":
    main()
