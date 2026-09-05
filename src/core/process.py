"""Subprocess boundaries shared by commands."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any


def run(*args: str | Path, capture: bool = False, check: bool = True, **kwargs: Any) -> subprocess.CompletedProcess:
    return subprocess.run([str(value) for value in args], check=check, text=True,
                          capture_output=capture, **kwargs)


def run_json(*args: str | Path) -> Any:
    return json.loads(run(*args, capture=True).stdout)
