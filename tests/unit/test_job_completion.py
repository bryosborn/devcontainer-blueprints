"""A successful Docker client exit must not hide an incomplete job script."""
import importlib.util
from pathlib import Path
import subprocess
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("image_test", ROOT / "tests/integration/image/run.py")
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class JobCompletionTests(unittest.TestCase):
    def exercise(self, output, state, *, timeout=False):
        calls = []
        inspections = 0

        def docker(args, **kwargs):
            nonlocal inspections
            calls.append(args)
            if args[1] == "create":
                return SimpleNamespace(stdout="disposable-test-container\n")
            if args[1] == "wait" and timeout:
                raise subprocess.TimeoutExpired(args, kwargs["timeout"])
            if args[1] == "logs":
                return SimpleNamespace(stdout=output, stderr="")
            if args[1] == "inspect":
                inspections += 1
                value = ({"HostConfig": {"Privileged": False, "NetworkMode": "none", "Binds": None}}
                         if inspections == 1 else {"State": state})
                return SimpleNamespace(stdout=runtime.json.dumps([value]))
            return SimpleNamespace(stdout="0\n")

        try:
            with patch.object(runtime, "run", side_effect=docker), patch("builtins.print"):
                runtime.run_script("test/image", "linux/arm64", "echo fixture")
        finally:
            self.assertIn(["docker", "rm", "-f", "disposable-test-container"], calls)

    def test_complete_success(self):
        self.exercise("fixture\nTOOLBOX_JOB_SCRIPT_COMPLETED\n", {"ExitCode": 0})

    def test_early_success_is_rejected(self):
        with self.assertRaisesRegex(AssertionError, "before completing"):
            self.exercise("fixture started\n", {"ExitCode": 0})

    def test_container_failure_overrides_client_success(self):
        with self.assertRaisesRegex(AssertionError, "script failed"):
            self.exercise("TOOLBOX_JOB_SCRIPT_COMPLETED\n", {"ExitCode": 137, "OOMKilled": True})

    def test_timeout_removes_only_its_container(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            self.exercise("", {}, timeout=True)


if __name__ == "__main__":
    unittest.main()
