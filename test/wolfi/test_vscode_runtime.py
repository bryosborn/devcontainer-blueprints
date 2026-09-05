#!/usr/bin/env python3
"""Exercise optional extension probes and the single-image VS Code test runner."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
COMPONENT_TEST = ROOT / "src/wolfi/image/test-extension-components.mjs"
NODE = shutil.which("node")


@unittest.skipUnless(NODE, "Node is required for VS Code runtime tests")
class VSCodeRuntimeTests(unittest.TestCase):
    def test_empty_extension_selection_needs_no_language_runtimes(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([NODE, str(COMPONENT_TEST), directory],
                                    text=True, capture_output=True, check=True)
            self.assertIn("BOUNDARY:", result.stdout)
            self.assertNotIn("PASS ", result.stdout)

    def test_selected_yaml_answers_lsp_while_optional_java_is_unavailable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            extensions = root / "extensions"
            extensions.mkdir()
            # Missing optional Java is checked before attempting to start JDT LS.
            (extensions / "redhat.java-1.0.0").mkdir()
            yaml = extensions / "redhat.vscode-yaml-1.0.0"
            (yaml / "dist").mkdir(parents=True)
            (yaml / "package.json").write_text(json.dumps({"publisher": "redhat", "name": "vscode-yaml"}))
            (yaml / "dist/languageserver.js").write_text(
                'process.stdin.once("data", () => { '
                'const response=JSON.stringify({jsonrpc:"2.0",id:1,result:{capabilities:{}}});'
                'process.stdout.write(`Content-Length: ${Buffer.byteLength(response)}\\r\\n\\r\\n${response}`); });'
            )
            fake_bin = root / "bin"
            fake_bin.mkdir()
            (fake_bin / "sh").symlink_to("/bin/sh")
            result = subprocess.run([NODE, str(COMPONENT_TEST), str(extensions)],
                                    env={**os.environ, "PATH": str(fake_bin)}, text=True, capture_output=True, check=True)
            self.assertIn("SKIP redhat.java: optional runtime unavailable (java)", result.stdout)
            self.assertIn("PASS YAML language server", result.stdout)
            self.assertNotIn("PASS Rust", result.stdout)

    def test_schema2_root_image_defaults_to_install_and_quick_skips_it(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lock = root / "lock.json"
            lock.write_text(json.dumps({"schemaVersion": 2, "image": {"reference": "test/vscode:root", "platform": "linux/amd64"},
                                        "config": {}, "resolved": {"vscode": {"commit": "a" * 40, "productVersion": "1.100.0"}}}))
            fake_bin = root / "bin"
            fake_bin.mkdir()
            docker = fake_bin / "docker"
            docker.write_text('''#!/usr/bin/env python3
import json,os,sys
args=sys.argv[1:]
if args[:2]==['image','inspect']:
    if '--format' in args:
        expression=args[args.index('--format')+1]
        print('linux/amd64' if '.Os' in expression else os.environ['WOLFI_TEST_LOCK_SHA'])
    else: print('[]')
elif args[0]=='create':
    with open(os.environ['WOLFI_TEST_RUN_ARGS'],'w') as output: json.dump(args,output)
    print('fixture-container')
elif args[0] in ('start','rm'): pass
elif args[0]=='wait': print('0')
elif args[0]=='logs':
    if os.environ.get('WOLFI_TEST_FAILURE')!='missing-marker': print('WOLFI_VSCODE_SCRIPT_COMPLETED')
elif args[0]=='inspect':
    failure=os.environ.get('WOLFI_TEST_FAILURE')
    print(json.dumps({'ExitCode': 17 if failure=='failed-state' else 0, 'OOMKilled': failure=='oom-state'}))
else: sys.exit(2)
''')
            docker.chmod(0o755)
            args_file = root / "run-args.json"
            env = {**os.environ, "PATH": f"{fake_bin}:{os.environ['PATH']}",
                   "WOLFI_TEST_LOCK_SHA": hashlib.sha256(lock.read_bytes()).hexdigest(),
                   "WOLFI_TEST_RUN_ARGS": str(args_file)}
            for flags, install in (([], "true"), (["--quick"], "false")):
                subprocess.run([str(ROOT / "src/wolfi/image/test-vscode.sh"), "--lock", str(lock), *flags],
                               env=env, text=True, capture_output=True, check=True)
                args = json.loads(args_file.read_text())
                self.assertEqual(args[args.index("--user") + 1], "root")
                self.assertIn("EXPECTED_REMOTE_HOME=/root", args)
                self.assertIn("HAS_EXTENSIONS=false", args)
                self.assertIn(f"INSTALL_EXTENSIONS={install}", args)
                self.assertIn("--network=none", args)
            for failure in ("missing-marker", "failed-state", "oom-state"):
                with self.subTest(failure=failure):
                    result = subprocess.run([str(ROOT / "src/wolfi/image/test-vscode.sh"), "--lock", str(lock), "--quick"],
                                            env={**env, "WOLFI_TEST_FAILURE": failure}, text=True, capture_output=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("ERROR: Offline VS Code test", result.stderr)


if __name__ == "__main__":
    unittest.main()
