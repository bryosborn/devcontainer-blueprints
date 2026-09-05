#!/usr/bin/env python3
"""Build one fixture through dev Docker, build Docker, and Kaniko; compare semantics."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import shlex
import subprocess
import sys
import tarfile
import tempfile
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from src.core.hashing import timestamp, write_json
from src.core.profile import Profile, WorkflowError
from src.core.process import run, run_json


KANIKO_TEST = ROOT / "tests/integration/components/kaniko_build.py"
spec = importlib.util.spec_from_file_location("kaniko_build_support", KANIKO_TEST)
support = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(support)


DOCKERFILE = """ARG BASE_IMAGE
FROM ${BASE_IMAGE} AS prepare
RUN set -eu; install -d -m 0755 /fixture-out; \\
    printf '#!/bin/sh\\nprintf "fixture:%%s\\n" "${1:-missing}"\\n' >/fixture-out/run.sh; \\
    printf 'deterministic fixture\\n' >/fixture-out/payload.txt; \\
    chmod 0755 /fixture-out/run.sh; chmod 0644 /fixture-out/payload.txt; \\
    chown -R 1234:2345 /fixture-out
FROM ${BASE_IMAGE}
COPY --from=prepare --chown=1234:2345 /fixture-out /fixture
RUN set -eu; ln -s payload.txt /fixture/current; chown -h 1234:2345 /fixture/current
ENV FIXTURE_ALPHA=one FIXTURE_BETA="two words"
LABEL toolbox.fixture.contract="1" toolbox.fixture.purpose="builder-equivalence"
USER 1234:2345
WORKDIR /fixture
ENTRYPOINT ["/bin/sh", "/fixture/run.sh"]
CMD ["default"]
"""


def docker_job(create: list[str], description: str) -> None:
    container = run(*create, capture=True).stdout.strip()
    try:
        details = run_json("docker", "inspect", container)[0]
        if details["HostConfig"]["Privileged"] or details["HostConfig"]["NetworkMode"] != "none":
            raise WorkflowError(f"{description} job is privileged or externally networked")
        run("docker", "start", container, capture=True)
        status = run("docker", "wait", container, capture=True).stdout.strip()
        logs = run("docker", "logs", container, capture=True, check=False)
        if status != "0":
            raise WorkflowError(f"{description} failed:\n{logs.stdout}{logs.stderr}")
    finally:
        run("docker", "rm", "-f", container, check=False, capture=True)


def stage_context_volume(context: Path, volume: str, image: str, platform: str) -> None:
    run("docker", "volume", "create", volume, capture=True)
    container = run(
        "docker", "create", "--platform", platform,
        "--mount", f"type=volume,source={volume},target=/fixture",
        "--entrypoint", "/bin/sleep", image, "300", capture=True,
    ).stdout.strip()
    try:
        run("docker", "cp", f"{context}/.", f"{container}:/fixture")
    finally:
        run("docker", "rm", "-f", container, check=False, capture=True)


def docker_build(profile: Profile, context_volume: str, tag: str, base: str, dev_proxy: bool) -> None:
    inner = ["docker", "build", "--pull=false", "--network=none", "--platform", profile.platform,
             "--build-arg", f"BASE_IMAGE={base}", "--tag", tag, "/fixture"]
    common = ["docker", "create", "--platform", profile.platform, "--network=none",
              "--mount", f"type=volume,source={context_volume},target=/fixture,readonly"]
    if dev_proxy:
        command = shlex.join(["cd", "/fixture"]) + "; " + shlex.join(inner)
        create = [*common,
                  "--mount", "type=bind,source=/var/run/docker.sock,target=/var/run/docker-host.sock",
                  "--user", "0", "--entrypoint", "/usr/local/share/wolfi-dod/docker-socket-proxy-entrypoint.sh",
                  profile.image, "su", "-s", "/bin/bash", profile.lock["config"]["user"]["name"],
                  "-c", command]
        docker_job(create, "dev-profile Docker build")
    else:
        create = [*common,
                  "--mount", "type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock",
                  "--user", "0", "--entrypoint", "/bin/bash", profile.image, "-c",
                  "cd /fixture; " + shlex.join(inner)]
        docker_job(create, "build-profile Docker build")


def kaniko_build(profile: Profile, context: Path, tag: str, output: Path) -> None:
    artifact = profile.lock["resolved"]["apk"]["baseImage"]["artifact"]
    archive = ROOT / artifact["artifactDirectory"] / artifact["file"]
    cache = output / "cache"
    base = support.cache_base(archive, artifact["sha256"], profile.platform, cache)
    tar_path = output / "image.tar"
    identity = "toolbox-equivalence-kaniko-" + uuid.uuid4().hex[:12]
    volume = identity + "-workspace"
    container = identity + "-job"
    create = [
        "docker", "create", "--name", container, "--platform", profile.platform,
        "--network=none", "--user", "0",
        "--mount", f"type=volume,source={volume},target=/kaniko/work",
        "--entrypoint", "/usr/local/bin/kaniko-build", profile.image,
        "--context", "/kaniko/work/context", "--dockerfile", "/kaniko/work/context/Dockerfile",
        "--build-arg", f"BASE_IMAGE={base}", "--cache=true", "--cache-dir=/kaniko/cache",
        "--cache-run-layers=false", "--cache-copy-layers=false", "--no-push", "--no-push-cache",
        "--destination", tag, "--tar-path", "/kaniko/work/image.tar", "--verbosity=warn",
    ]
    try:
        run("docker", "volume", "create", volume, capture=True)
        run(*create, capture=True)
        run("docker", "cp", str(context), f"{container}:/kaniko/work/context")
        run("docker", "cp", str(cache), f"{container}:/kaniko/cache")
        details = run_json("docker", "inspect", container)[0]
        if details["HostConfig"]["Privileged"] or details["HostConfig"]["NetworkMode"] != "none":
            raise WorkflowError("Kaniko comparison job is privileged or externally networked")
        if any(mount["Type"] == "bind" for mount in details.get("Mounts", [])):
            raise WorkflowError("Kaniko comparison job unexpectedly received a host bind mount")
        run("docker", "start", container, capture=True)
        status = run("docker", "wait", container, capture=True).stdout.strip()
        logs = run("docker", "logs", container, capture=True, check=False)
        if status != "0":
            raise WorkflowError(f"Kaniko build failed:\n{logs.stdout}{logs.stderr}")
        run("docker", "cp", f"{container}:/kaniko/work/image.tar", tar_path)
        if not tar_path.is_file():
            raise WorkflowError("Kaniko did not produce its requested image archive")
        run("docker", "load", "--input", tar_path)
    finally:
        run("docker", "rm", "-f", container, check=False, capture=True)
        run("docker", "volume", "rm", volume, check=False, capture=True)


RUNTIME_PATHS = {".dockerenv", "etc/hostname", "etc/hosts", "etc/resolv.conf"}


def filesystem_manifest(image: str, workspace: Path) -> dict[str, dict]:
    container = run("docker", "create", image, capture=True).stdout.strip()
    archive = workspace / f"{image.replace('/', '_').replace(':', '_')}.rootfs.tar"
    try:
        run("docker", "export", "--output", archive, container)
    finally:
        run("docker", "rm", "-f", container, check=False, capture=True)
    manifest: dict[str, dict] = {}
    with tarfile.open(archive, "r:") as rootfs:
        for member in rootfs:
            name = member.name.removeprefix("./").lstrip("/").rstrip("/")
            if not name or name in RUNTIME_PATHS:
                continue
            if name in manifest:
                raise WorkflowError(f"Duplicate effective filesystem entry: {name}")
            record = {"mode": member.mode, "uid": member.uid, "gid": member.gid}
            if member.isdir():
                record["type"] = "directory"
            elif member.issym():
                record.update(type="symlink", target=member.linkname)
            elif member.islnk():
                record.update(type="hardlink", target=member.linkname)
            elif member.isfile():
                source = rootfs.extractfile(member)
                assert source is not None
                record.update(type="file", sha256=hashlib.sha256(source.read()).hexdigest())
            else:
                record.update(type="special", deviceMajor=member.devmajor, deviceMinor=member.devminor)
            manifest[name] = record
    forbidden = ("kaniko/", "workspace/context", "usr/local/bin/kaniko-build", "opt/wolfi-builder-marker")
    contamination = [name for name in manifest if any(name == item.rstrip("/") or name.startswith(item) for item in forbidden)]
    if contamination:
        raise WorkflowError(f"Builder contamination in {image}: {contamination[:5]}")
    return manifest


def config_contract(image: str) -> dict:
    details = run_json("docker", "image", "inspect", image)[0]
    config = details["Config"]
    labels = config.get("Labels") or {}
    return {
        "platform": f"{details['Os']}/{details['Architecture']}",
        "user": config.get("User") or "",
        "environment": sorted(config.get("Env") or []),
        "workingDirectory": config.get("WorkingDir") or "",
        "entrypoint": config.get("Entrypoint") or [],
        "command": config.get("Cmd") or [],
        "declaredLabels": {key: labels[key] for key in sorted(labels) if key.startswith("toolbox.fixture.")},
    }


def comparison_difference(values: dict[str, dict]) -> dict:
    baseline = values["dev"]
    result = {}
    for name, candidate in values.items():
        if name == "dev":
            continue
        missing = sorted(set(baseline) - set(candidate))
        extra = sorted(set(candidate) - set(baseline))
        changed = [key for key in sorted(set(baseline) & set(candidate)) if baseline[key] != candidate[key]]
        if missing or extra or changed:
            result[name] = {
                "missing": missing[:20],
                "extra": extra[:20],
                "changed": {key: {"dev": baseline[key], name: candidate[key]} for key in changed[:20]},
            }
    return result


def runtime_contract(image: str, platform: str) -> list[dict]:
    results = []
    for arguments, expected in (([], "fixture:default\n"), (["explicit"], "fixture:explicit\n")):
        completed = run("docker", "run", "--rm", "--platform", platform, "--network=none", image, *arguments,
                        capture=True, check=False)
        result = {"arguments": arguments, "exitCode": completed.returncode, "stdout": completed.stdout,
                  "stderr": completed.stderr}
        if result["exitCode"] != 0 or result["stdout"] != expected or result["stderr"]:
            raise WorkflowError(f"Runtime contract failed for {image}: {result}")
        results.append(result)
    return results


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    profiles = {name: Profile(name) for name in ("dev", "build", "kaniko")}
    for profile in profiles.values():
        profile.verify()
        profile.inspect()
    platforms = {profile.platform for profile in profiles.values()}
    base_digests = {profile.lock["resolved"]["apk"]["baseImage"]["digest"] for profile in profiles.values()}
    if len(platforms) != 1 or len(base_digests) != 1:
        raise WorkflowError("Builder profiles do not share one platform and immutable fixture base")

    identifier = uuid.uuid4().hex[:12]
    tags = {name: f"toolbox-equivalence-{name}:{identifier}" for name in profiles}
    context_volume = f"toolbox-equivalence-context-{identifier}"
    (ROOT / ".tmp").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="builder-equivalence-", dir=ROOT / ".tmp") as directory:
        workspace = Path(directory)
        context = workspace / "context"
        context.mkdir()
        (context / "Dockerfile").write_text(DOCKERFILE, encoding="utf-8")
        (context / ".dockerignore").write_text(".git\n", encoding="utf-8")
        base = profiles["dev"].lock["resolved"]["apk"]["baseImage"]["artifact"]["localReference"]
        try:
            stage_context_volume(context, context_volume, profiles["build"].image, profiles["build"].platform)
            docker_build(profiles["dev"], context_volume, tags["dev"], base, True)
            docker_build(profiles["build"], context_volume, tags["build"], base, False)
            output = workspace / "kaniko-output"
            output.mkdir()
            kaniko_build(profiles["kaniko"], context, tags["kaniko"], output)
            manifests = {name: filesystem_manifest(tag, workspace) for name, tag in tags.items()}
            configs = {name: config_contract(tag) for name, tag in tags.items()}
            runtimes = {name: runtime_contract(tag, profiles[name].platform) for name, tag in tags.items()}
            if len({json.dumps(value, sort_keys=True) for value in manifests.values()}) != 1:
                raise WorkflowError("Docker and Kaniko effective filesystem entries differ:\n" +
                                    json.dumps(comparison_difference(manifests), indent=2))
            if len({json.dumps(value, sort_keys=True) for value in configs.values()}) != 1:
                raise WorkflowError("Docker and Kaniko image configuration contracts differ")
            if len({json.dumps(value, sort_keys=True) for value in runtimes.values()}) != 1:
                raise WorkflowError("Docker and Kaniko runtime output differs")
            result = {
                "schemaVersion": 1,
                "generatedAt": timestamp(),
                "passed": True,
                "platform": platforms.pop(),
                "baseDigest": base_digests.pop(),
                "builders": {name: {"profileImage": profile.image, "outputImageId": run_json("docker", "image", "inspect", tags[name])[0]["Id"]}
                             for name, profile in profiles.items()},
                "filesystemEntries": len(manifests["dev"]),
                "filesystemManifestSha256": hashlib.sha256(json.dumps(manifests["dev"], sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
                "configuration": configs["dev"],
                "runtimeCases": runtimes["dev"],
                "ignoredEncodingDifferences": ["image digest", "layers", "history", "creation timestamps"],
            }
            write_json(args.output, result)
            print("Docker (dev/build) and Kaniko builder semantics match.")
        finally:
            for tag in tags.values():
                run("docker", "image", "rm", "--force", tag, check=False, capture=True)
            run("docker", "volume", "rm", context_volume, check=False, capture=True)


if __name__ == "__main__":
    main()
