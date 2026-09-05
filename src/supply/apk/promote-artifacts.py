#!/usr/bin/env python3
"""Promote a staged Wolfi APK/base supply while preserving prior artifacts on error."""

from __future__ import annotations

import argparse
import os
import shutil
import tempfile
import uuid
from pathlib import Path

from supply_lib import SupplyError


ARTIFACT_NAMES = ("apk", "docker-images", "base-image.artifact.json")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--staging-platform", required=True, type=Path)
    parser.add_argument("--destination-platform", required=True, type=Path)
    parser.add_argument("--fragment-source", required=True, type=Path)
    parser.add_argument("--fragment-destination", required=True, type=Path)
    return parser.parse_args()


def remove_generated(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink(missing_ok=True)
    elif path.is_dir():
        shutil.rmtree(path)


def main() -> None:
    args = parse_args()
    staging = args.staging_platform.resolve()
    destination = args.destination_platform.resolve()
    fragment_source = args.fragment_source.resolve()
    fragment_destination = args.fragment_destination.resolve()

    try:
        if staging == destination or staging in destination.parents or destination in staging.parents:
            raise SupplyError("staging and destination platform paths must be separate")
        for name in ARTIFACT_NAMES:
            if not (staging / name).exists():
                raise SupplyError(f"staging output is missing {name}")
        if not fragment_source.is_file():
            raise SupplyError("staging output is missing the resolver fragment")

        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.mkdir(parents=True, exist_ok=True)
        fragment_destination.parent.mkdir(parents=True, exist_ok=True)
        lock_directory = destination.parent / f".{destination.name}.promotion.lock"
        try:
            lock_directory.mkdir()
        except FileExistsError as error:
            raise SupplyError(
                f"another artifact promotion may be active: {lock_directory}"
            ) from error

        backup = Path(
            tempfile.mkdtemp(
                prefix=f".{destination.name}.backup.", dir=destination.parent
            )
        )
        promoted: list[str] = []
        fragment_temporary = fragment_destination.with_name(
            f".{fragment_destination.name}.{uuid.uuid4().hex}.tmp"
        )
        try:
            for name in ARTIFACT_NAMES:
                current = destination / name
                if current.exists() or current.is_symlink():
                    os.replace(current, backup / name)
                os.replace(staging / name, current)
                promoted.append(name)

            with fragment_source.open("rb") as source, fragment_temporary.open(
                "xb"
            ) as output:
                shutil.copyfileobj(source, output)
                output.flush()
                os.fsync(output.fileno())
            os.replace(fragment_temporary, fragment_destination)
        except Exception:
            fragment_temporary.unlink(missing_ok=True)
            for name in reversed(promoted):
                remove_generated(destination / name)
                old = backup / name
                if old.exists() or old.is_symlink():
                    os.replace(old, destination / name)
            raise
        finally:
            remove_generated(backup)
            lock_directory.rmdir()

        print(f"Promoted Wolfi artifacts into {destination}")
    except (OSError, SupplyError) as error:
        raise SystemExit(f"ERROR: {error}") from error


if __name__ == "__main__":
    main()
