#!/usr/bin/env python3
"""Run the Playwright fixture from a real isolated VS Code Dev Containers task."""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import tarfile
import time
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]


def run(command, **kwargs):
    return subprocess.run([str(value) for value in command], check=True, **kwargs)


def output(command):
    return run(command, capture_output=True, text=True).stdout.strip()


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def inspect_image(reference):
    return json.loads(output(["docker", "image", "inspect", reference]))[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--lock", required=True, type=Path)
    parser.add_argument("--harness-manifest", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path, help="New isolated result directory")
    args = parser.parse_args()
    run(["bash", "-c", 'source "$1/src/cli/common.sh"; wolfi_verify_lock "$1" "$2" "$3"',
         "wolfi-playwright-vscode", ROOT, args.config, args.lock])
    lock = json.loads(args.lock.read_bytes())
    config = lock["config"]
    if not (config.get("devcontainer") and config.get("vscode") and config.get("playwright")):
        raise ValueError("Select an image with devcontainer, VS Code, and Playwright enabled")
    if config.get("docker", {}).get("socket") is not True:
        raise ValueError("The Dev browser acceptance profile requires its configured socket proxy")
    harness = json.loads(args.harness_manifest.read_text())
    required_files = {"source.lock.json", "vscode-metadata.json", "vscode.tar.gz", "devcontainers.vsix",
                      "SHA256SUMS", "harness.Dockerfile"}
    if harness.get("schemaVersion") != 1 or len(harness.get("files", [])) != len(required_files):
        raise ValueError("Incomplete VS Code harness manifest")
    if {record["file"] for record in harness["files"]} != required_files:
        raise ValueError("Unexpected VS Code harness artifact manifest")
    for record in harness["files"]:
        file = args.harness_manifest.parent / record["file"]
        if digest(file) != record["sha256"] or file.stat().st_size != record["size"]:
            raise ValueError(f"Corrupt harness artifact: {file}")
    if digest(args.harness_manifest.parent / "source.lock.json") != harness["sourceLockSha256"]:
        raise ValueError("Harness source lock differs from its recorded provenance")
    editor_image = inspect_image(harness["imageId"])
    if f"{editor_image['Os']}/{editor_image['Architecture']}" != harness["platform"]:
        raise ValueError("Harness platform mismatch")
    if harness["vscode"]["commit"] != lock["resolved"]["vscode"]["commit"]:
        raise ValueError("Desktop and locked server commit differ")
    image = inspect_image(lock["image"]["reference"])
    lock_hash = digest(args.lock)
    if image["Config"]["Labels"].get("devcontainer-blueprints.lock.sha256") != lock_hash:
        raise ValueError("Target image lock label differs")
    if f"{image['Os']}/{image['Architecture']}" != lock["image"]["platform"]:
        raise ValueError("Target image platform differs")
    result = args.output.resolve()
    result.mkdir(parents=True, exist_ok=False)
    workspace = result / "workspace"
    shutil.copytree(ROOT / "tests/fixtures/playwright", workspace)
    shutil.copytree(HERE / "extension", workspace / ".acceptance-extension")
    runner = lock["resolved"]["playwright"]["testRunner"]
    runner_file = ROOT / runner["file"]
    if digest(runner_file) != runner["sha256"]:
        raise ValueError("Playwright test runner archive differs from lock")
    with tarfile.open(runner_file) as archive:
        for member in archive.getmembers():
            resolved = (workspace / member.name).resolve()
            if workspace != resolved and workspace not in resolved.parents:
                raise ValueError("Unsafe runner archive path")
        archive.extractall(workspace, filter="data")
    (workspace / ".vscode").mkdir(exist_ok=True)
    (workspace / ".vscode/tasks.json").write_text(json.dumps({"version": "2.0.0", "tasks": [{
        "label": "Toolbox: Playwright visual acceptance", "type": "process", "command": "/bin/bash",
        "args": ["-c", "set -o pipefail; bash ./run-fixture.sh 2>&1 | tee vscode-task.log"],
        "options": {"cwd": "${workspaceFolder}"}, "problemMatcher": [],
        "presentation": {"reveal": "always", "panel": "dedicated"}}]}, indent=2) + "\n")
    identifier = uuid.uuid4().hex[:12]
    volume = f"wolfi-playwright-vscode-{identifier}"
    client_root = f"/test/{identifier}"
    remote_root = "/workspaces/playwright"
    client_data = result / "client-data"
    (client_data / "workspace/.devcontainer").mkdir(parents=True)
    dc = {"name": f"Toolbox Playwright editor acceptance {identifier}",
          "image": lock["image"]["reference"], "workspaceFolder": remote_root,
          "workspaceMount": f"source={volume},target={remote_root},type=volume",
          "runArgs": ["--platform", lock["image"]["platform"], "--network=none", "--shm-size=1g"],
          "overrideCommand": True, "shutdownAction": "none",
          "customizations": {"vscode": {"extensions": []}}}
    (client_data / "workspace/.devcontainer/devcontainer.json").write_text(json.dumps(dc, indent=2))
    docker_wrapper = client_data / "docker-offline"
    docker_wrapper.write_text('#!/bin/sh\nset -eu\nif [ "${1:-}" = build ]; then\n'
                              '  shift\n  exec /usr/bin/docker build --network=none "$@"\n'
                              'fi\nexec /usr/bin/docker "$@"\n')
    docker_wrapper.chmod(0o755)
    settings = client_data / "user-data/User"
    settings.mkdir(parents=True)
    (settings / "settings.json").write_text(json.dumps({
        "telemetry.telemetryLevel": "off", "update.mode": "none", "extensions.autoUpdate": False,
        "extensions.autoCheckUpdates": False, "extensions.ignoreRecommendations": True,
        "security.workspace.trust.enabled": False, "dev.containers.copyGitConfig": False,
        "dev.containers.gitCredentialHelperConfigLocation": "none", "dev.containers.cacheVolume": False,
        "dev.containers.dockerPath": client_root + "/docker-offline",
        "dev.containers.defaultExtensions": [], "dev.containers.mountWaylandSocket": False,
        "chat.disableAIFeatures": True, "workbench.startupEditor": "none"}, indent=2))
    authority = "dev-container+" + json.dumps({"hostPath": client_root + "/workspace",
                                               "localDocker": True}, separators=(",", ":")).encode().hex()
    remote = "vscode-remote://" + authority + remote_root
    # The isolated client uses the bootstrap's named 1000:1000 identity. The
    # Dev Containers extension synchronizes the remote account to that identity.
    uid = gid = 1000
    creator = client = None
    targets = []
    adjusted_images = []
    started = time.time()
    try:
        run(["docker", "volume", "create", volume], stdout=subprocess.DEVNULL)
        creator = output(["docker", "create", "--platform", lock["image"]["platform"], "--network=none",
                          "--user", "0", "--entrypoint", "/bin/sh", "--mount",
                          f"source={volume},target={remote_root},type=volume", image["Id"],
                          "-c", "sleep 600"])
        run(["docker", "start", creator], stdout=subprocess.DEVNULL)
        manifest_hash = output(["docker", "exec", creator, "sha256sum", "/opt/playwright/manifest.json"]).split()[0]
        expected = {"user": config["user"]["name"], "uid": uid, "gid": gid,
                    "vscodeVersion": lock["resolved"]["vscode"]["productVersion"],
                    "playwrightManifestSha256": manifest_hash}
        (workspace / "vscode-expected.json").write_text(json.dumps(expected))
        run(["docker", "cp", str(workspace) + "/.", f"{creator}:{remote_root}"])
        run(["docker", "exec", creator, "chown", "-R", f"{uid}:{gid}", remote_root])
        run(["docker", "rm", "-f", creator], stdout=subprocess.DEVNULL)
        creator = None
        code_args = ["/opt/vscode/code", "--no-sandbox", "--disable-gpu-sandbox", "--disable-gpu",
                     "--disable-updates", "--skip-welcome", "--skip-release-notes", "--disable-workspace-trust",
                     "--user-data-dir", client_root + "/user-data", "--extensions-dir", "/opt/extensions",
                     "--logsPath", client_root + "/logs", "--crash-reporter-directory", client_root + "/crashes",
                     "--folder-uri", remote,
                     "--extensionDevelopmentPath=" + remote + "/.acceptance-extension",
                     "--extensionTestsPath=" + remote + "/.acceptance-extension/runner.cjs"]
        client = output(["docker", "create", "--platform", harness["platform"], "--network=none",
                         "--user", "1000:1000", "--group-add", str(os.stat("/var/run/docker.sock").st_gid),
                         "--init", "--shm-size=1g", "--entrypoint", "xvfb-run",
                         "--mount", "type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock",
                         "-e", "ELECTRON_ENABLE_LOGGING=1", "-e", "DOCKER_HOST=unix:///var/run/docker.sock",
                         harness["imageId"], "-a", "-e", "/dev/stderr", "-s", "-screen 0 1440x1000x24", *code_args])
        run(["docker", "cp", str(client_data) + "/.", f"{client}:{client_root}"])
        run(["docker", "start", client], stdout=subprocess.DEVNULL)
        while time.time() - started < 600:
            state = json.loads(output(["docker", "inspect", client]))[0]["State"]
            if not state["Running"]:
                break
            time.sleep(2)
        else:
            raise TimeoutError("Official VS Code remote task did not complete within ten minutes")
        logs = subprocess.run(["docker", "logs", client], capture_output=True)
        (result / "vscode-desktop.stdout.log").write_bytes(logs.stdout)
        (result / "vscode-desktop.stderr.log").write_bytes(logs.stderr)
        targets = output(["docker", "ps", "-aq", "--filter",
                          f"label=devcontainer.local_folder={client_root}/workspace"]).splitlines()
        if len(targets) != 1:
            raise AssertionError(f"Expected one actual Dev Container, found {len(targets)}")
        target = targets[0]
        target_details = json.loads(output(["docker", "inspect", target]))[0]
        adjusted = target_details["Config"]["Image"]
        if adjusted.startswith("vsc-workspace-") and adjusted.endswith("-uid"):
            adjusted_images.append(adjusted)
        if target_details["Config"].get("Labels", {}).get("devcontainer-blueprints.lock.sha256") != lock_hash:
            raise AssertionError("Dev Container differs from the selected locked image")
        socket_mounts = [mount for mount in target_details.get("Mounts", [])
                         if mount.get("Destination") in {"/var/run/docker.sock", "/var/run/docker-host.sock"}]
        if len(socket_mounts) != 1 or socket_mounts[0]["Destination"] != "/var/run/docker-host.sock":
            raise AssertionError("Dev target did not preserve the source-socket/proxy boundary")
        if any(mount.get("Name") == "vscode" for mount in target_details.get("Mounts", [])):
            raise AssertionError("Editor acceptance must not use the active editor's shared cache volume")
        run(["docker", "exec", target, "/bin/sh", "-c",
             "test -S /var/run/docker.sock && test -S /var/run/docker-host.sock && "
             "command -v docker >/dev/null && ! command -v dockerd && ! command -v containerd"])
        if target_details["HostConfig"].get("ShmSize") != 1024 * 1024 * 1024:
            raise AssertionError("Expected a private 1 GiB shared-memory allocation")
        if target_details["HostConfig"].get("Privileged") or target_details["HostConfig"].get("IpcMode") == "host":
            raise AssertionError("Browser acceptance must not use privileged mode or host IPC")
        run(["docker", "cp", f"{target}:{remote_root}/.", str(workspace)])
        subprocess.run(["docker", "cp", f"{target}:/home/{config['user']['name']}/.vscode-server/data/logs",
                        str(result / "remote-server-logs")], capture_output=True)
        run(["docker", "cp", f"{client}:{client_root}/.", str(client_data)])
        evidence = json.loads((workspace / "vscode-result.json").read_text())
        if state["ExitCode"] != 0 or state.get("OOMKilled") or evidence["status"] != "PASS":
            raise AssertionError("VS Code task acceptance failed")
        server_errors = re.compile(r"\b(?:EACCES|EPERM)\b|Extension host terminated unexpectedly|Activating extension .+ failed")
        for log_file in (result / "remote-server-logs").rglob("*.log"):
            if server_errors.search(log_file.read_text(errors="replace")):
                raise AssertionError(f"VS Code Server runtime error: inspect {log_file}")
        evidence.update({"imageId": image["Id"], "containerImageId": target_details["Image"],
                         "lockSha256": lock_hash, "harnessImageId": harness["imageId"],
                         "harnessManifestSha256": digest(args.harness_manifest),
                         "targetNetwork": target_details["HostConfig"]["NetworkMode"],
                         "editorNetwork": "none", "elapsedSeconds": round(time.time() - started, 2)})
        if evidence["targetNetwork"] != "none":
            raise AssertionError("Target browser test network was not disabled")
        proof_files = set((workspace / "results").rglob("*"))
        proof_files.update((result / "remote-server-logs").rglob("*"))
        proof_files.update((client_data / "logs").rglob("*"))
        proof_files.update([workspace / "vscode-task.log", workspace / "vscode-result.json",
                            result / "vscode-desktop.stdout.log", result / "vscode-desktop.stderr.log"])
        evidence["artifacts"] = [{"file": str(path.relative_to(result)), "sha256": digest(path),
                                  "size": path.stat().st_size}
                                 for path in sorted(proof_files) if path.is_file()]
        (result / "acceptance.json").write_text(json.dumps(evidence, indent=2) + "\n")
        print(json.dumps({"status": "PASS", "report": str(result / "acceptance.json"),
                          "screenshots": [str(path) for path in (workspace / "results").glob("*.png")]}))
    finally:
        if client:
            logs = subprocess.run(["docker", "logs", client], capture_output=True)
            (result / "vscode-desktop.stdout.log").write_bytes(logs.stdout)
            (result / "vscode-desktop.stderr.log").write_bytes(logs.stderr)
            subprocess.run(["docker", "cp", f"{client}:{client_root}/.", str(client_data)], capture_output=True)
        if not targets:
            targets = output(["docker", "ps", "-aq", "--filter",
                              f"label=devcontainer.local_folder={client_root}/workspace"]).splitlines()
        for container in targets:
            details = json.loads(output(["docker", "inspect", container]))[0]
            adjusted = details["Config"]["Image"]
            if adjusted.startswith("vsc-workspace-") and adjusted.endswith("-uid"):
                adjusted_images.append(adjusted)
            subprocess.run(["docker", "cp", f"{container}:{remote_root}/.", str(workspace)], capture_output=True)
            if not (result / "remote-server-logs").exists():
                subprocess.run(["docker", "cp", f"{container}:/home/{config['user']['name']}/.vscode-server/data/logs",
                                str(result / "remote-server-logs")], capture_output=True)
        for container in [*targets, creator, client]:
            if container:
                subprocess.run(["docker", "rm", "-f", container], capture_output=True)
        for adjusted in set(adjusted_images):
            subprocess.run(["docker", "image", "rm", adjusted], capture_output=True)
        subprocess.run(["docker", "volume", "rm", volume], capture_output=True)


if __name__ == "__main__":
    main()
