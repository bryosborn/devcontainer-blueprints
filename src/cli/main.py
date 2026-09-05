"""Single public command dispatcher for toolbox image profiles."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from src.cli.cleanup import clean
from src.cli.transfer import load, package
from src.core.profile import REPO, Profile, WorkflowError, load_settings, select_cleanup
from src.core.process import run
from src.scan.command import publish_scan_evidence, scan


COMMANDS = ("update-lock", "prefetch", "build", "test", "scan", "package", "load", "clean")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        prog="./scripts/images.sh",
        description="Build, test, scan, and transfer one locked toolbox image profile.",
    )
    result.add_argument("command", choices=COMMANDS)
    result.add_argument("target", help="dev, build, kaniko, or all")
    result.add_argument("--keep-workspace", action="store_true")
    result.add_argument("--offline", action="store_true")
    result.add_argument("--quick", action="store_true")
    result.add_argument("--skip-db-download", action="store_true")
    result.add_argument("--include-vsix-archive", action="store_true")
    result.add_argument("--skip-acceptance-gate", action="store_true")
    result.add_argument("--output", type=Path)
    result.add_argument("--dry-run", action="store_true")
    result.add_argument("--docker-images", action="store_true")
    return result


def require_options(args: argparse.Namespace) -> None:
    accepted = {
        "update-lock": {"keep_workspace"},
        "prefetch": {"offline"},
        "build": {"keep_workspace"},
        "test": {"quick"},
        "scan": {"skip_db_download", "include_vsix_archive", "skip_acceptance_gate"},
        "package": {"output"},
        "load": set(),
        "clean": {"dry_run", "docker_images"},
    }[args.command]
    supplied = {
        name for name in (
            "keep_workspace", "offline", "quick", "skip_db_download", "include_vsix_archive",
            "skip_acceptance_gate", "output", "dry_run", "docker_images"
        ) if getattr(args, name)
    }
    unexpected = supplied - accepted
    if unexpected:
        raise WorkflowError(f"{args.command} does not accept: {', '.join('--' + key.replace('_', '-') for key in sorted(unexpected))}")
    if args.target == "all" and args.output:
        raise WorkflowError("--output can only package one profile")
    if args.target == "all" and args.command == "test" and args.quick:
        raise WorkflowError("test all always runs the complete acceptance suite")
    if args.target == "all" and args.command == "scan" and (args.include_vsix_archive or args.skip_acceptance_gate):
        raise WorkflowError("scan all always applies the release exclusions and Critical/High gate")


def paths(name: str) -> tuple[Path, Path]:
    return REPO / "config" / f"{name}.yaml", REPO / "config" / f"{name}.lock.json"


def invoke_internal(name: str, args: argparse.Namespace) -> None:
    config, lock = paths(name)
    if args.command == "update-lock":
        command = [REPO / "src/cli/update-lock.sh", "--config", config, "--lock", lock]
        if args.keep_workspace:
            command.append("--keep-workspace")
        run(*command)
        return
    profile = Profile(name)
    if args.command == "prefetch":
        command = [REPO / "src/cli/prefetch.sh", "--config", config, "--lock", lock]
        if args.offline:
            command.append("--offline")
        run(*command)
    elif args.command == "build":
        command = ["python3", REPO / "src/image/build.py", "--config", config, "--lock", lock]
        if args.keep_workspace:
            command.append("--keep-workspace")
        run(*command)
    elif args.command == "test":
        command = ["python3", REPO / "tests/integration/image/run.py", "--config", config, "--lock", lock]
        if args.quick:
            command.append("--quick")
        run(*command)
    elif args.command == "scan":
        scan_args = argparse.Namespace(
            output_dir=None,
            cache_dir=None,
            skip_db_download=args.skip_db_download,
            skip_acceptance_gate=args.skip_acceptance_gate,
            include_vsix_archive=args.include_vsix_archive,
        )
        scan(profile, scan_args)
    elif args.command == "package":
        package(profile, argparse.Namespace(output=args.output))
    elif args.command == "load":
        load(profile, argparse.Namespace())
    elif args.command == "clean":
        clean(select_cleanup(name), argparse.Namespace(dry_run=args.dry_run, docker_images=args.docker_images))


def shared_selection(lock: dict) -> str:
    config = lock["config"]
    return json.dumps({
        "platform": config["image"]["platform"],
        "wolfi": config["wolfi"],
        "build": config["build"],
        "playwright": config.get("playwright"),
        "utilities": config["utilities"],
    }, sort_keys=True, separators=(",", ":"))


def update_all(names: tuple[str, ...], args: argparse.Namespace) -> None:
    (REPO / ".tmp").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="update-lock-all-", dir=REPO / ".tmp") as directory:
        staged = Path(directory)
        selections: list[str] = []
        locks: list[tuple[Path, Path]] = []
        for name in names:
            config, destination = paths(name)
            candidate = staged / f"{name}.lock.json"
            command = [REPO / "src/cli/update-lock.sh", "--config", config, "--lock", candidate]
            if args.keep_workspace:
                command.append("--keep-workspace")
            run(*command)
            value = json.loads(candidate.read_text(encoding="utf-8"))
            selections.append(shared_selection(value))
            locks.append((candidate, destination))
        if len(set(selections)) != 1:
            raise WorkflowError("Shared build, Playwright, utility, repository, or platform selections differ across profiles")
        for candidate, destination in locks:
            candidate.replace(destination)
    print("Refreshed all profile locks as one validated set.")


def test_all(names: tuple[str, ...]) -> None:
    for name in names:
        invoke_internal(name, argparse.Namespace(command="test", quick=False))
    result_path = REPO / ".tmp/builder-equivalence.json"
    result_path.parent.mkdir(exist_ok=True)
    run("python3", REPO / "tests/acceptance/builder_equivalence.py", "--output", result_path)
    run("python3", REPO / "tests/acceptance/write_test_report.py", "--builder-result", result_path)


def scan_all(names: tuple[str, ...], args: argparse.Namespace) -> None:
    (REPO / ".tmp").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="scan-all-", dir=REPO / ".tmp") as directory:
        stage = Path(directory)
        cache = stage / "trivy-cache"
        profiles = [Profile(name) for name in names]
        contexts = []
        outputs = []
        for index, profile in enumerate(profiles):
            output = stage / "raw" / profile.name
            scan_args = argparse.Namespace(
                output_dir=output,
                cache_dir=cache,
                skip_db_download=args.skip_db_download or index > 0,
                skip_acceptance_gate=False,
                include_vsix_archive=False,
            )
            scan(profile, scan_args)
            metadata = json.loads((output / "scan-metadata.json").read_text(encoding="utf-8"))
            contexts.append(json.dumps(metadata["trivy"], sort_keys=True))
            outputs.append(output)
        if len(set(contexts)) != 1:
            raise WorkflowError("Trivy or database identity changed during the sequential scan set")
        publish_scan_evidence(profiles, outputs, cache)


def main() -> None:
    args = parser().parse_args()
    settings = load_settings()
    if args.target != "all" and args.target not in settings.profiles:
        raise WorkflowError(f"Unknown profile {args.target!r}; expected {', '.join(settings.profiles)} or all")
    require_options(args)
    names = settings.profiles if args.target == "all" else (args.target,)
    if args.command == "update-lock" and args.target == "all":
        update_all(names, args)
    elif args.command == "test" and args.target == "all":
        test_all(names)
    elif args.command == "scan" and args.target == "all":
        scan_all(names, args)
    else:
        for name in names:
            invoke_internal(name, args)


if __name__ == "__main__":
    try:
        main()
    except (WorkflowError, OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"ERROR: {error}") from error
