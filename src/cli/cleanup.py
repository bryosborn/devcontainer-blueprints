"""Profile-scoped generated-state cleanup."""

from __future__ import annotations

import argparse
import shutil
import sys

from src.core.process import run
from src.core.profile import CleanSelection, Profile

def clean(profile: Profile | CleanSelection, args: argparse.Namespace) -> None:
    profile.verify()
    targets = [profile.root]
    bundle = profile.repo / f"artifacts-{profile.config.stem}-{profile.platform.replace('/', '-')}.tar.gz"
    targets.extend([bundle, bundle.with_name(bundle.name + ".sha256")])
    for target in targets:
        if target.exists():
            print(f"{'Would remove' if args.dry_run else 'Removing'}: {target}")
            if not args.dry_run:
                if target.is_dir():
                    shutil.rmtree(target)
                else:
                    target.unlink()
    if args.docker_images:
        result = run("docker", "image", "inspect", profile.image, capture=True, check=False)
        if result.returncode == 0:
            print(f"{'Would remove' if args.dry_run else 'Removing'} image: {profile.image}")
            if not args.dry_run:
                removed = run("docker", "image", "rm", profile.image, check=False)
                if removed.returncode:
                    print("Retained image because Docker could not remove it.", file=sys.stderr)
