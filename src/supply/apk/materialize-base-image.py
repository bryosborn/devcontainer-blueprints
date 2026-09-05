#!/usr/bin/env python3
"""Materialize and save one digest-pinned Wolfi base-image platform."""

from __future__ import annotations

import argparse
import json
import os
import tempfile
import uuid
from pathlib import Path

from supply_lib import (
    SupplyError,
    ensure_empty_directory,
    platform_key,
    require_oci_digest,
    require_platform,
    require_relative_path,
    run,
    sha256_file,
    validate_pinned_image,
    write_json_atomic,
)


SCRIPT_DIR = Path(__file__).resolve().parent
CONTEXT_DIR = SCRIPT_DIR
DOCKERFILE = CONTEXT_DIR / "Dockerfile.materialize"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pinned-image", required=True)
    parser.add_argument("--expected-digest", required=True)
    parser.add_argument("--platform", required=True)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument(
        "--artifact-directory",
        required=True,
        help="Platform-qualified, repository-relative base artifact directory.",
    )
    parser.add_argument("--metadata", required=True, type=Path)
    parser.add_argument("--expected-tar-sha256")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    try:
        platform, architecture = require_platform(args.platform)
        digest = require_oci_digest(args.expected_digest, "expected base digest")
        _repository, reference_digest = validate_pinned_image(
            args.pinned_image, digest
        )
        artifact_directory = require_relative_path(
            args.artifact_directory, "base artifact directory"
        ).as_posix()
        output_dir = args.output_dir.resolve()
        ensure_empty_directory(output_dir, "base-image artifact output")

        short_digest = reference_digest.removeprefix("sha256:")[:16]
        local_reference = (
            f"devcontainer-blueprints/wolfi-base-lock:"
            f"{platform_key(platform)}-{short_digest}"
        )
        run(
            [
                "docker",
                "build",
                "--pull",
                "--provenance=false",
                "--platform",
                platform,
                "--build-arg",
                f"BASE_IMAGE={args.pinned_image}",
                "--label",
                f"devcontainers.wolfi.base.digest={digest}",
                "--label",
                f"devcontainers.wolfi.base.source={args.pinned_image}",
                "--tag",
                local_reference,
                "--file",
                str(DOCKERFILE),
                str(CONTEXT_DIR),
            ]
        )
        inspected = run(
            ["docker", "image", "inspect", local_reference], capture_output=True
        )
        try:
            image_metadata = json.loads(inspected.stdout)[0]
        except (json.JSONDecodeError, IndexError, TypeError) as error:
            raise SupplyError(f"docker returned invalid image metadata: {error}") from error
        actual_platform = (
            f"{image_metadata.get('Os')}/{image_metadata.get('Architecture')}"
        )
        if actual_platform != platform:
            raise SupplyError(
                f"materialized image platform is {actual_platform}, expected {platform}"
            )

        filename = f"wolfi-base-{platform_key(platform)}-{short_digest}.tar"
        output_path = output_dir / filename
        temporary = output_dir / f".{filename}.{uuid.uuid4().hex}.tmp"
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
            tar_sha256 = sha256_file(temporary)
            if (
                args.expected_tar_sha256 is not None
                and tar_sha256 != args.expected_tar_sha256
            ):
                raise SupplyError(
                    "regenerated base-image tar SHA256 does not match the frozen lock: "
                    f"expected {args.expected_tar_sha256}, got {tar_sha256}"
                )
            os.replace(temporary, output_path)
        finally:
            temporary.unlink(missing_ok=True)

        metadata = {
            "schemaVersion": 1,
            "platform": platform,
            "pinnedReference": args.pinned_image,
            "digest": digest,
            "localReference": local_reference,
            "artifactDirectory": artifact_directory,
            "file": f"docker-images/{filename}",
            "sha256": tar_sha256,
            "size": output_path.stat().st_size,
        }
        write_json_atomic(args.metadata.resolve(), metadata)
        print(f"Saved {args.pinned_image} as {output_path}")
    except SupplyError as error:
        raise SystemExit(f"ERROR: {error}") from error


if __name__ == "__main__":
    main()
