#!/usr/bin/env python3
"""Run real offline Chromium fixtures and retain screenshots, traces and logs."""
import argparse
import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import shlex
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("playwright_supply", ROOT / "src/supply/vendor/playwright_supply.py")
supply = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(supply)


def run(command, **kwargs):
    return subprocess.run([str(value) for value in command], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", required=True, type=Path)
    parser.add_argument("--quick", action="store_true", help="Skip extra root/changed-UID cases on named-user profiles")
    args = parser.parse_args()
    raw = args.lock.read_bytes()
    lock = json.loads(raw)
    config = lock["config"]
    if "playwright" not in config:
        raise SystemExit("ERROR: Playwright is not selected in this profile")
    record = lock["resolved"]["playwright"]
    platform = lock["image"]["platform"]
    reference = lock["image"]["reference"]
    digest = hashlib.sha256(raw).hexdigest()
    details = json.loads(run(["docker", "image", "inspect", reference], capture_output=True, text=True).stdout)[0]
    if f"{details['Os']}/{details['Architecture']}" != platform or details["Config"].get("Labels", {}).get("devcontainer-blueprints.lock.sha256") != digest:
        raise SystemExit("ERROR: Playwright test image platform/lock label mismatch")
    image_id = details["Id"]
    def verify_only(url, path, expected, offline=False):
        if not offline or not path.is_file() or supply.sha256(path) != expected:
            raise SystemExit(f"ERROR: missing or altered frozen Playwright artifact: {path}")
    supply.prefetch(record, ROOT, verify_only, offline=True, config=config)
    runner = ROOT / record["testRunner"]["file"]
    reports = ROOT / config["artifacts"]["root"] / platform.replace("/", "-") / "reports/playwright"
    reports.mkdir(parents=True, exist_ok=True)
    summary_path = reports / "summary.json"
    summary_path.unlink(missing_ok=True)
    user = config.get("user", {}).get("name", "root")
    identities = [(user, config.get("user", {}).get("uid", 0), config.get("user", {}).get("gid", 0), False)]
    if user != "root" and not args.quick:
        identities = [("root", 0, 0, False), *identities]
        if (config["user"]["uid"], config["user"]["gid"]) != (2101, 3201):
            identities.append((user, 2101, 3201, True))
    outcomes = []
    for identity, uid, gid, update in identities:
        for mode in ("headless-shell", "full-chromium", "headed"):
            label = f"{identity}-{uid}-{gid}-{mode}"
            output = reports / label
            if output.exists():
                shutil.rmtree(output)
            output.mkdir()
            executable = "sh ./run-fixture.sh"
            if mode == "headed":
                executable = "xvfb-run -a -e /dev/stderr sh ./run-fixture.sh --headed"
            script = ["set -Eeuo pipefail", "cd /tmp/toolbox-playwright-fixture",
                      "tar -xzof /tmp/toolbox-playwright-runner.tar.gz", "rm /tmp/toolbox-playwright-runner.tar.gz",
                      "test ! -S /var/run/docker.sock", "test ! -S /var/run/docker-host.sock",
                      "test ! -e /opt/playwright/browsers/ffmpeg-1011"]
            if update:
                script += [f"groupmod -g {gid} {shlex.quote(config['user']['name'])}",
                           f"usermod -u {uid} -g {gid} {shlex.quote(identity)}",
                           f"chown {uid}:{gid} /home/{shlex.quote(identity)}"]
            script += [f"chown -R {uid}:{gid} /tmp/toolbox-playwright-fixture",
                       f"export PLAYWRIGHT_BROWSERS_PATH={supply.CACHE_PATH}"]
            if mode == "full-chromium":
                script.append("export PW_FIXTURE_CHANNEL=chromium")
            else:
                script.append("unset PW_FIXTURE_CHANNEL")
            command = f"set -eu; cd /tmp/toolbox-playwright-fixture; test \"$(id -u)\" = {uid}; test \"$(id -g)\" = {gid}; {executable}"
            script.append(command if identity == "root" else f"su -s /bin/sh {shlex.quote(identity)} -c {shlex.quote(command)}")
            script.append("printf '%s\\n' TOOLBOX_PLAYWRIGHT_CONTAINER_COMPLETED")
            container = run(["docker", "create", "--platform", platform, "--network=none", "--ipc=private", "--shm-size=1g",
                             "--init", "--user", "0", "--entrypoint", "/bin/bash", image_id, "-c", "\n".join(script)],
                            capture_output=True, text=True).stdout.strip()
            try:
                run(["docker", "cp", ROOT / "tests/fixtures/playwright", f"{container}:/tmp/toolbox-playwright-fixture"])
                run(["docker", "cp", runner, f"{container}:/tmp/toolbox-playwright-runner.tar.gz"])
                run(["docker", "start", container], stdout=subprocess.DEVNULL)
                timed_out = False
                try:
                    run(["docker", "wait", container], capture_output=True, text=True, timeout=300)
                except subprocess.TimeoutExpired:
                    timed_out = True
                logs = run(["docker", "logs", container], capture_output=True, text=True)
                (output / "stdout.log").write_text(logs.stdout)
                (output / "stderr.log").write_text(logs.stderr)
                print(logs.stdout, end="", flush=True)
                print(logs.stderr, end="", flush=True)
                state = json.loads(run(["docker", "inspect", container], capture_output=True, text=True).stdout)[0]["State"]
                copied = subprocess.run(["docker", "cp", f"{container}:/tmp/toolbox-playwright-fixture/results/.", str(output)], capture_output=True, text=True)
                if timed_out or state["ExitCode"] != 0 or state.get("OOMKilled") or copied.returncode:
                    raise RuntimeError(f"Playwright {label} failed; inspect {output}")
                if "TOOLBOX_PLAYWRIGHT_FIXTURE_PASS" not in logs.stdout or logs.stdout.splitlines()[-1:] != ["TOOLBOX_PLAYWRIGHT_CONTAINER_COMPLETED"]:
                    raise RuntimeError(f"Playwright {label} did not complete every fixture")
                report = json.loads((output / "report.json").read_text())
                if report["stats"]["expected"] != 2 or any(report["stats"][key] for key in ("unexpected", "flaky", "skipped")):
                    raise RuntimeError(f"Playwright {label} did not pass both viewport tests")
                files = [
                    {"file": path.relative_to(reports).as_posix(), "sha256": supply.sha256(path), "size": path.stat().st_size}
                    for path in sorted(output.rglob("*")) if path.is_file()
                ]
                outcome = {"case": label, "uid": uid, "gid": gid, "mode": mode, "passed": 2, "files": files}
                outcomes.append(outcome)
            finally:
                run(["docker", "rm", "-f", container], stdout=subprocess.DEVNULL)
    summary = {
        "schemaVersion": 1,
        "createdAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "image": reference,
        "imageId": image_id,
        "platform": platform,
        "lockSha256": digest,
        "version": record["version"],
        "browserVersion": record["browserVersion"],
        "video": False,
        "network": "none",
        "ipc": "private",
        "shmBytes": 1073741824,
        "cases": outcomes,
        "visualReview": "pending: inspect desktop-initial.png, desktop.png and mobile.png with view_image",
    }
    summary_path.write_text(json.dumps(summary, indent=2) + "\n")
    print(f"Passed Playwright fixtures; screenshots, traces and hashes: {reports}")


if __name__ == "__main__":
    main()
