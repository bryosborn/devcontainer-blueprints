#!/usr/bin/env python3
"""Exercise embedded Kaniko in an isolated, network-disabled Docker job."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import uuid


def run(*args, **kwargs):
    return subprocess.run(list(args), check=True, text=True, **kwargs)


def cache_base(archive, expected, target, destination):
    digest = hashlib.sha256()
    with archive.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != expected:
        raise RuntimeError("Fixture base archive differs from verified SHA256")

    with tarfile.open(archive) as source:
        def blob(descriptor):
            name = "blobs/" + descriptor["digest"].replace(":", "/")
            data = source.extractfile(name).read()
            if hashlib.sha256(data).hexdigest() != descriptor["digest"].split(":")[1]:
                raise RuntimeError("Fixture OCI blob differs from digest")
            return data

        def select(index):
            for descriptor in index["manifests"]:
                data = json.loads(blob(descriptor))
                if "manifests" in data:
                    result = select(data)
                    if result:
                        return result
                elif "config" in data:
                    config = json.loads(blob(data["config"]))
                    if f"{config.get('os')}/{config.get('architecture')}" == target:
                        return descriptor, data
            return None

        selected = select(json.loads(source.extractfile("index.json").read()))
        if not selected:
            raise RuntimeError("No runnable fixture base for selected architecture")
        descriptor, manifest = selected
        directory = destination / descriptor["digest"]
        blobs = directory / "blobs/sha256"
        blobs.mkdir(parents=True)
        for item in [descriptor, manifest["config"], *manifest["layers"]]:
            (blobs / item["digest"].split(":")[1]).write_bytes(blob(item))
        (directory / "index.json").write_text(json.dumps({
            "schemaVersion": 2,
            "manifests": [descriptor],
        }))
        (directory / "oci-layout").write_text('{"imageLayoutVersion":"1.0.0"}')
        return "example.invalid/verified-wolfi@" + descriptor["digest"]


def check_output(path):
    with tarfile.open(path) as output:
        manifest = json.loads(output.extractfile("manifest.json").read())
        saw_result = False
        forbidden = {
            "opt/wolfi-builder-marker",
            "usr/local/bin/kaniko-build",
            "kaniko/executor",
        }
        for layer in manifest[0]["Layers"]:
            with tarfile.open(fileobj=output.extractfile(layer), mode="r:*") as contents:
                for member in contents:
                    name = member.name.removeprefix("./").lstrip("/")
                    if name in forbidden:
                        raise RuntimeError("Builder filesystem contaminated target image: " + name)
                    if name == "result":
                        if contents.extractfile(member).read() != b"fixture-content\n":
                            raise RuntimeError("Wrong compiled fixture output")
                        saw_result = True
        if not saw_result:
            raise RuntimeError("Produced image lacks multistage fixture result")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True)
    parser.add_argument("--platform", required=True, choices=["linux/amd64", "linux/arm64"])
    parser.add_argument("--base-archive", required=True, type=Path)
    parser.add_argument("--base-sha256", required=True)
    args = parser.parse_args()
    identity = "wolfi-kaniko-" + uuid.uuid4().hex[:12]
    container = identity + "-job"
    volume = identity + "-workspace"
    created = False

    with tempfile.TemporaryDirectory(prefix="wolfi-kaniko-") as scratch:
        root = Path(scratch)
        context = root / "context"
        context.mkdir()
        base = cache_base(args.base_archive, args.base_sha256, args.platform, root / "cache")
        (context / "input.txt").write_text("fixture-content\n")
        (context / "Dockerfile").write_text(
            f"FROM {base} AS compile\n"
            "COPY input.txt /input\n"
            "RUN test ! -e /opt/wolfi-builder-marker && cat /input > /result\n"
            f"FROM {base}\n"
            "COPY --from=compile /result /result\n"
        )
        (context / "Dockerfile.failure").write_text(
            f"FROM {base}\nRUN echo expected-failure >&2; exit 17\n"
        )
        runner = root / "runner.sh"
        runner.write_text('''#!/bin/bash
set -Eeuo pipefail
mkdir -p /opt
printf marker >/opt/wolfi-builder-marker
original="$(sha256sum /workspace/context/input.txt)"
common=(--context /workspace/context --cache=true --cache-dir=/kaniko/cache --cache-run-layers=false --cache-copy-layers=false --no-push --no-push-cache --destination example.invalid/fixture:local --verbosity=warn)
kaniko-build "${common[@]}" --dockerfile /workspace/context/Dockerfile --tar-path /workspace/output.tar
[[ "$(sha256sum /workspace/context/input.txt)" == "$original" ]]
[[ "$(cat /opt/wolfi-builder-marker)" == marker ]]
command -v bash git jq >/dev/null
if kaniko-build "${common[@]}" --dockerfile /workspace/context/Dockerfile.failure >/workspace/failure.log 2>&1; then
  echo 'Expected Dockerfile failure succeeded' >&2; exit 1
fi
grep -F expected-failure /workspace/failure.log >/dev/null
[[ "$(sha256sum /workspace/context/input.txt)" == "$original" ]]
[[ "$(cat /opt/wolfi-builder-marker)" == marker ]]
command -v bash git jq >/dev/null
printf 'KANIKO_DISPOSABLE_TEST_COMPLETE\\n'
''')
        try:
            run("docker", "volume", "create", volume, capture_output=True)
            run(
                "docker", "create", "--name", container, "--platform", args.platform,
                "--network=none", "--user", "0",
                "--mount", f"type=volume,source={volume},target=/workspace",
                "--entrypoint", "/bin/bash", args.image, "/kaniko/runner.sh",
                capture_output=True,
            )
            created = True
            run("docker", "cp", str(context), container + ":/workspace/context")
            run("docker", "cp", str(root / "cache"), container + ":/kaniko/cache")
            run("docker", "cp", str(runner), container + ":/kaniko/runner.sh")
            run("docker", "start", container, capture_output=True)
            result = run("docker", "wait", container, capture_output=True)
            logs = run("docker", "logs", container, capture_output=True)
            print(logs.stdout, end="")
            print(logs.stderr, end="")
            if result.stdout.strip() != "0" or "KANIKO_DISPOSABLE_TEST_COMPLETE" not in logs.stdout:
                raise RuntimeError("Kaniko build/restore fixture failed")
            output = root / "output.tar"
            run("docker", "cp", container + ":/workspace/output.tar", str(output))
            check_output(output)
            rejected = subprocess.run([
                "docker", "run", "--rm", "--network=none", "--platform", args.platform,
                "--user", "1001:1001", "--entrypoint", "/usr/local/bin/kaniko-build",
                args.image, "--context", "/kaniko/context",
            ], text=True, capture_output=True)
            if rejected.returncode == 0 or "requires UID 0" not in rejected.stderr:
                raise RuntimeError("Kaniko wrapper did not reject non-root execution")
            print("Kaniko multistage RUN, handled failure, workspace/rootfs preservation, "
                  "clean output and non-root checks passed.")
        finally:
            if created:
                subprocess.run(["docker", "rm", "-f", container], check=False, capture_output=True)
            subprocess.run(["docker", "volume", "rm", volume], check=False, capture_output=True)


if __name__ == "__main__":
    main()
