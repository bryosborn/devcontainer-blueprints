#!/usr/bin/env python3
"""Publish retained test evidence after the complete three-profile suite passes."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from src.core.hashing import sha256, timestamp, write_text
from src.core.profile import Profile, REPO


UTILITY_OPERATIONS = {
    "curl": "loopback HTTP download",
    "wget": "loopback HTTP download",
    "openssh-client": "ssh configuration plus scp/sftp parsing",
    "openssh-keygen": "Ed25519 generation and public-key derivation",
    "openssh-keyscan": "strict CLI parsing",
    "zip": "ZIP creation/listing",
    "unzip": "archive verification/extraction",
    "less": "pager reads fixture",
    "procps": "process and memory inspection",
    "findutils": "GNU find/xargs deterministic operations",
    "kubectl": "client-only ConfigMap generation",
    "yq": "YAML transformation",
    "helm": "offline chart lint/render",
    "oras": "OCI-layout push/fetch/pull round trip",
    "mongosh": "local JavaScript evaluation without a server",
    "mongodbDatabaseTools": "tool versions plus BSON decode",
    "rsync": "local file copy",
    "nano": "editor startup/help",
    "bind-tools": "deterministic local UDP DNS lookup",
    "iproute2": "loopback address and listener inspection",
    "iputils": "loopback ping and tracepath",
    "netcat-openbsd": "loopback TCP client/server transfer",
}


def human_size(value: int) -> str:
    size = float(value)
    for unit in ("B", "KiB", "MiB", "GiB"):
        if size < 1024 or unit == "GiB":
            return f"{size:.0f} {unit}" if unit == "B" else f"{size:.1f} {unit}"
        size /= 1024
    raise AssertionError


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--builder-result", required=True, type=Path)
    args = parser.parse_args()
    builder = json.loads(args.builder_result.read_text(encoding="utf-8"))
    if builder.get("passed") is not True:
        raise SystemExit("ERROR: builder equivalence result did not pass")
    profiles = [Profile(name) for name in ("dev", "build", "kaniko")]
    summaries = {}
    rows = []
    for profile in profiles:
        profile.verify()
        identity = profile.inspect()
        summary_path = profile.platform_root / "reports/playwright/summary.json"
        summary = json.loads(summary_path.read_text(encoding="utf-8"))
        if (summary.get("image") != profile.image or summary.get("imageId") != identity["Id"]
                or summary.get("lockSha256") != profile.digest
                or any(case.get("passed") != 2 for case in summary.get("cases", []))):
            raise SystemExit(f"ERROR: stale or incomplete Playwright result for {profile.name}")
        summaries[profile.name] = summary
        rows.append((profile, identity, profile.docker_list_size(identity["Id"]), summary))

    lines = ["# Toolbox image test report", "", f"Generated: `{timestamp()}`", "",
             "The complete AMD64 profile suite and cross-builder acceptance test passed.", "",
             "| Profile | Image | Immutable image ID | Docker size | Content size | Playwright modes | Lock SHA256 |",
             "| --- | --- | --- | ---: | ---: | ---: | --- |"]
    for profile, identity, docker_size, summary in rows:
        lines.append(f"| {profile.name} | `{profile.image}` | `{identity['Id']}` | {docker_size} | {human_size(identity['Size'])} | {len(summary['cases'])} | `{profile.digest}` |")
    lines += ["", "`Docker size` is the rounded value from `docker image ls`; `Content size` is Docker's exact `inspect .Size` value rendered in IEC units.",
              "", "## Profile boundaries", "",
              "- **dev:** named `vscode` identity, writable home, UID/GID update matrix, VS Code server/layout/archive checks, and identity-owned Docker socket proxy with source-socket preservation.",
              "- **build:** root GitLab-style shell, Docker CLI/Buildx/Compose through only an explicit host-socket mount, and no daemon or Dev Container metadata.",
              "- **kaniko:** root GitLab-style shell, no Docker command/socket/daemon or VS Code payload, plus multistage `RUN`, handled-failure cleanup, mounted-context preservation, output contamination, and root-only checks.",
              "- Ordinary runtime and browser jobs used `--network=none`, no privileged mode, and no host mounts. Network utility checks used loopback only.",
              "", "## Compiler and runtime coverage", "",
              "C and C++, Clang, CMake, OpenSSL, Python 3.12/3.13 with venv and pip, Java/Javac, offline Maven validation, Node/npm/npx/Corepack, and Rust/Cargo/rustfmt/Clippy/rust-analyzer LSP all completed against local fixtures.",
              "", "## Utility coverage", "", "| Configuration key | Verified operation |", "| --- | --- |"]
    for name, operation in UTILITY_OPERATIONS.items():
        lines.append(f"| `{name}` | {operation} |")
    lines += ["", "## Playwright", "",
              "Each profile passed Chromium headless-shell, full Chromium headless, and headed Chromium under Xvfb. Each mode rendered desktop and mobile fixtures, produced correctly sized PNGs, and produced two traces without video.", ""]
    for name, summary in summaries.items():
        modes = ", ".join(case["case"] for case in summary["cases"])
        lines.append(f"- **{name}:** Playwright `{summary['version']}`, browser `{summary['browserVersion']}`; {modes}. Summary SHA256 before cleanup: `{sha256(profiles[[p.name for p in profiles].index(name)].platform_root / 'reports/playwright/summary.json')}`")
    lines += ["", "## Builder equivalence", "",
              f"The dev socket-proxy Docker build, build-profile direct-socket Docker build, and Kaniko build produced the same {builder['filesystemEntries']} normalized filesystem entries (`{builder['filesystemManifestSha256']}`).",
              "", "The comparison covered paths, file hashes, modes, ownership, symlink targets, platform, user, environment, working directory, entrypoint, command, declared fixture labels, runtime output, exit status, and builder contamination. Image digests, layer layout, history, and creation timestamps were intentionally outside the contract.", ""]
    write_text(REPO / "reports/tests.md", "\n".join(lines))
    print(f"Published {REPO / 'reports/tests.md'}")


if __name__ == "__main__":
    main()
