#!/usr/bin/env python3
"""Run selected capability checks in disposable, network-disabled containers."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent


def run(command, **kwargs):
    return subprocess.run([str(x) for x in command], check=True, **kwargs)


def run_script(image, platform, script, env=None):
    """Wait for the container itself and require the complete job script to run."""
    marker = "WOLFI_JOB_SCRIPT_COMPLETED"
    command = ["docker", "create", "--platform", platform, "--network=none", "--entrypoint", "/bin/bash"]
    for key, value in (env or {}).items():
        command += ["-e", f"{key}={value}"]
    container = run([*command, image, "-c", script + f"\nprintf '%s\\n' '{marker}'\n"],
                    capture_output=True, text=True).stdout.strip()
    try:
        run(["docker", "start", container], stdout=subprocess.DEVNULL)
        # Some Docker attach streams can close before all output is delivered.
        # A detached job, authoritative exit state and completion marker prevent
        # an incomplete noninteractive shell run from being reported as success.
        run(["docker", "wait", container], capture_output=True, text=True, timeout=600)
        output = run(["docker", "logs", container], capture_output=True, text=True)
        print(output.stdout, end="", flush=True)
        print(output.stderr, end="", flush=True)
        state = json.loads(run(["docker", "inspect", container], capture_output=True, text=True).stdout)[0]["State"]
        assert state["ExitCode"] == 0 and not state.get("OOMKilled"), "offline job script failed"
        assert output.stdout.splitlines()[-1:] == [marker], "offline job script ended before completing every fixture"
    finally:
        run(["docker", "rm", "-f", container], stdout=subprocess.DEVNULL)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--lock", required=True, type=Path)
    parser.add_argument("--quick", action="store_true")
    args = parser.parse_args()
    run(["bash", "-c", 'source "$1/scripts/wolfi/lib.sh"; wolfi_verify_lock "$1" "$2" "$3"',
         "wolfi-test", ROOT, args.config, args.lock])
    raw = args.lock.read_bytes()
    lock = json.loads(raw)
    config = lock["config"]
    image = lock["image"]["reference"]
    platform = lock["image"]["platform"]
    details = json.loads(run(["docker", "image", "inspect", image], capture_output=True, text=True).stdout)[0]
    assert f"{details['Os']}/{details['Architecture']}" == platform, "image platform differs from lock"
    labels = details["Config"].get("Labels") or {}
    assert labels.get("devcontainers.wolfi.lock.sha256") == hashlib.sha256(raw).hexdigest(), "image lock label differs"
    user = config.get("user", {}).get("name", "root")
    home = "/root" if user == "root" else f"/home/{user}"
    assert details["Config"]["User"] == ("0" if user == "root" else user), "incorrect image user"
    metadata = json.loads(labels.get("devcontainer.metadata", "[]"))
    if isinstance(metadata, dict):
        metadata = [metadata]
    socket = config.get("docker", {}).get("socket", False)
    if config.get("devcontainer", False):
        assert any(m.get("remoteUser") == user and m.get("updateRemoteUserUID") is True for m in metadata)
        assert any(m.get("containerUser") == "root" for m in metadata)
        assert any(m.get("init") is True for m in metadata)
    else:
        assert not metadata, "ordinary CI image contains Dev Container metadata"
        assert not details["Config"].get("Entrypoint"), "CI image intercepts GitLab's shell command"
    if not socket:
        assert not any(m.get("mounts") or m.get("entrypoint") for m in metadata), "socket metadata leaked"
        assert not any(e.startswith(("DOCKER_HOST=", "WOLFI_DOD_")) for e in details["Config"].get("Env", []))
    tools = config["toolchain"]
    env = {"EXPECTED_USER": user, "EXPECTED_HOME": home, "DEVCONTAINER": str(config.get("devcontainer", False)).lower(),
           "BUILD_ENABLED": str("build" in tools).lower(), "CLANG_ENABLED": str("clang" in tools.get("build", {})).lower(),
           "PYTHON_SELECTORS": " ".join(tools.get("python", [])), "RUST_TOOLCHAIN": tools.get("rust", {}).get("toolchain", ""),
           "RUST_COMPONENTS": " ".join(tools.get("rust", {}).get("components", []))}
    for key in ("java", "maven", "node", "npm", "clamav", "kubectl", "yq", "helm", "oras", "mongosh"):
        env[key.upper() + "_SELECTOR"] = tools.get(key, "")
    env["MONGODB_TOOLS_SELECTOR"] = tools.get("mongodbDatabaseTools", "")
    for key in ("cli", "buildx", "compose"):
        env["DOCKER_" + key.upper()] = str(key in config.get("docker", {})).lower()
    base = ["docker", "run", "--rm", "--platform", platform, "--network=none", "--entrypoint", "/bin/bash"]
    run_script(image, platform, (HERE / "test-runtime.sh").read_text(), env)
    absent = ["dockerd", "containerd", "kaniko", "executor"]
    for key, executable in {"kubectl": "kubectl", "rust": "rustc", "helm": "helm", "oras": "oras",
                            "mongosh": "mongosh", "mongodbDatabaseTools": "mongodump", "clamav": "clamscan"}.items():
        if key not in tools:
            absent.append(executable)
    for key, executable in {"cli": "docker", "compose": "docker-compose"}.items():
        if key not in config.get("docker", {}):
            absent.append(executable)
    absence_script = 'set -eu; for name in "$@"; do ! command -v "$name" >/dev/null 2>&1 || { echo "Unexpected command: $name"; exit 1; }; done'
    run([*base, image, "-c", absence_script, "wolfi-absence", *absent])
    if not socket:
        run([*base, image, "-c", "test ! -e /usr/local/share/wolfi-dod; test ! -S /var/run/docker.sock"])
    if "vscode" in config:
        command = [HERE / "test-vscode.sh", "--lock", args.lock]
        if args.quick:
            command += ["--quick"]
        run(command)
    else:
        run([*base, image, "-c", 'test ! -e "$HOME/.vscode-server"; test ! -e "$HOME/vscode-extensions.tar.gz"'])
    if "rust-analyzer" in tools.get("rust", {}).get("components", []):
        run_script(image, platform, (HERE / "test-rust-lsp.sh").read_text())
    if "helm" in tools:
        container = run(["docker", "create", "--platform", platform, "--network=none", "--entrypoint", "/bin/bash", image,
                         "-c", "set -eu; helm lint /tmp/helm-smoke; helm template wolfi /tmp/helm-smoke | grep wolfi-offline"],
                        capture_output=True, text=True).stdout.strip()
        try:
            run(["docker", "cp", HERE / "test/helm-smoke", f"{container}:/tmp/helm-smoke"])
            run(["docker", "start", "--attach", container])
            result = json.loads(run(["docker", "inspect", container], capture_output=True, text=True).stdout)[0]
            assert result["State"]["ExitCode"] == 0, "Helm smoke failed"
        finally:
            run(["docker", "rm", "-f", container], stdout=subprocess.DEVNULL)
    if config.get("devcontainer", False):
        command = [HERE / "test-devcontainer.sh", "--lock", args.lock]
        if args.quick:
            command += ["--identity", f"{config['user']['uid']}:{config['user']['gid']}"]
        run(command)
    print(f"Passed offline image checks: {image}")


if __name__ == "__main__":
    main()
