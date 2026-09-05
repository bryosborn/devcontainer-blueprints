#!/usr/bin/env python3
"""One selected lock, one build recipe, one output tag."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "src/wolfi"


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def image_footer(lock):
    config = lock["config"]
    user = config.get("user", {}).get("name", "root")
    home = "/root" if user == "root" else f"/home/{user}"
    env = {"HOME": home}
    if "java" in config["build"]:
        env["JAVA_HOME"] = "/opt/java"
    if "rust" in config["build"]:
        env.update(RUSTUP_HOME="/usr/local/rustup", CARGO_HOME=f"{home}/.cargo")
        env["PATH"] = f"{home}/.cargo/bin:/usr/local/cargo/bin:$PATH"
    if "playwright" in config:
        env["PLAYWRIGHT_BROWSERS_PATH"] = "/opt/playwright/browsers"
    if config.get("docker", {}).get("socket", False):
        env.update(DOCKER_HOST="unix:///var/run/docker.sock", WOLFI_DOD_REMOTE_USER=user)
    lines = [f"ENV {key}={json.dumps(value)}" for key, value in env.items()]
    lines += [f"USER {'0' if user == 'root' else user}", "WORKDIR /workspaces", 'CMD ["/bin/bash"]']
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--lock", required=True, type=Path)
    parser.add_argument("--keep-workspace", action="store_true")
    args = parser.parse_args()
    # Also verify when invoked directly rather than through the public dispatcher.
    run(["bash", "-c", 'source "$1/scripts/wolfi/lib.sh"; wolfi_verify_lock "$1" "$2" "$3"',
         "wolfi-build", ROOT, args.config, args.lock])
    run([ROOT / "scripts/wolfi/prefetch.sh", "--config", args.config, "--lock", args.lock, "--offline"])
    lock_bytes = args.lock.read_bytes()
    lock = json.loads(lock_bytes)
    config = lock["config"]
    selected = lock["resolved"]["apk"]["packageSets"]["final"]
    image = lock["image"]["reference"]
    platform = lock["image"]["platform"]
    (ROOT / ".tmp").mkdir(exist_ok=True)
    workspace = Path(tempfile.mkdtemp(prefix="wolfi-build-", dir=ROOT / ".tmp"))
    try:
        shutil.copytree(SOURCE / "components", workspace / "components")
        (workspace / "lock.json").write_bytes(lock_bytes)
        (workspace / "Dockerfile").write_text((SOURCE / "image/Dockerfile").read_text() + image_footer(lock))
        empty = workspace / "empty-vendor"
        empty.mkdir()
        vendor = ROOT / config["artifacts"]["root"] / platform.replace("/", "-") / "vendor"
        if not any(k in lock["resolved"] for k in ("vscode", "kubectl", "rust", "kaniko", "playwright")):
            vendor = empty
        build_args = {
            "BASE_IMAGE": lock["resolved"]["apk"]["baseImage"]["artifact"]["localReference"],
            "APK_ARCHITECTURE": lock["resolved"]["apk"]["architecture"],
            "APK_REPOSITORIES": " ".join(selected["repositorySubdirs"]),
            "APK_PACKAGES": " ".join(selected["packages"]),
        }
        options = ["--network=none", "--build-context", f"wolfi_apks={ROOT / selected['artifactDirectory']}",
                   "--build-context", f"wolfi_vendor={vendor}", "--label",
                   f"devcontainers.wolfi.lock.sha256={hashlib.sha256(lock_bytes).hexdigest()}"]
        if config.get("devcontainer", False):
            dc_dir = workspace / ".devcontainer"
            dc_dir.mkdir()
            dc = {"build": {"dockerfile": "../Dockerfile", "context": "..", "args": build_args, "options": options},
                  "containerUser": "root", "remoteUser": config["user"]["name"],
                  "updateRemoteUserUID": True, "init": True}
            if config.get("docker", {}).get("socket", False):
                shutil.copytree(SOURCE / "components/docker/feature", dc_dir / "features/docker-socket")
                dc["features"] = {"./features/docker-socket": {}}
            dc_file = dc_dir / "devcontainer.json"
            dc_file.write_text(json.dumps(dc, indent=2) + "\n")
            run(["devcontainer", "build", "--workspace-folder", workspace, "--config", dc_file,
                 "--image-name", image, "--platform", platform, "--no-lockfile"])
        else:
            command = ["docker", "build", "--platform", platform, *options, "--tag", image]
            for key, value in build_args.items():
                command += ["--build-arg", f"{key}={value}"]
            run([*command, workspace])
        run(["bash", "-c", 'source "$1/scripts/wolfi/lib.sh"; wolfi_verify_image_lock "$2" "$3"',
             "wolfi-build", ROOT, image, args.lock])
        print(f"Built {image} ({platform})", flush=True)
    finally:
        if args.keep_workspace:
            print(f"Build workspace: {workspace}")
        else:
            shutil.rmtree(workspace)


if __name__ == "__main__":
    main()
