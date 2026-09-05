# Real VS Code Playwright acceptance

This test opens the browser fixture in an official VS Code desktop client attached
to the selected Wolfi Dev Container. A test-only remote extension opens the source
and runs the workspace task through `vscode.tasks.executeTask`. The task runs the
same local Playwright fixture used by the container runtime check. No mock VS Code
API, active editor modification, installed production VSIX, or target dependency
installation is involved.

Prepare a host-native client while connected, using a dev lock whose extension
archive includes `ms-vscode-remote.remote-containers` and an existing native Wolfi
bootstrap image:

```sh
docker build --tag local/toolbox-bootstrap:test \
  --file .devcontainer/Dockerfile .
python3 tests/acceptance/playwright-vscode/prepare.py \
  --lock config/dev.lock.json \
  --base-image local/toolbox-bootstrap:test \
  --artifacts .tmp/playwright-vscode-harness/linux-arm64
```

Preparation downloads the official desktop at the locked server commit, checks
Microsoft's SHA256, verifies the lock's exact Dev Containers VSIX hash, and builds
a separate GUI client environment. Its generated manifest records the native
platform, immutable harness/base image IDs, original URLs and artifact hashes.
The small acceptance extension uses built-in Node modules and the real VS Code
API; it has no npm installation step. GUI libraries and Xvfb are confined to the
client harness so they cannot conceal missing target browser dependencies.

After building the locked Dev profile:

```sh
python3 tests/acceptance/playwright-vscode/run.py \
  --config config/dev.yaml \
  --lock config/dev.lock.json \
  --harness-manifest .tmp/playwright-vscode-harness/linux-arm64/manifest.json \
  --output .tmp/playwright-vscode-results
```

The result directory must be new. Runtime verifies the config/lock, output image
identity and label, client/server commit, harness hashes and frozen Playwright npm
archive. Both client and target containers use `--network=none`. The external
editor harness needs the Docker socket to establish the Dev Container connection;
the target receives the Dev profile's explicit source socket and validates its
identity-owned proxy boundary.
Its Docker wrapper adds `--network=none` to the extension's generated UID-update
build. The client's shared server cache is disabled; the target uses its baked
server and a dedicated workspace volume.
The test owns a temporary workspace volume and temporary containers and removes
only those resources afterward.

Success requires an actual remote Dev Containers extension host with the configured
remote user, VS Code version and browser manifest; a real task exit of zero; the
fixture's completion marker; and two successful browser scenarios with nonempty
desktop/mobile PNGs, a JSON report and traces. `acceptance.json` binds the browser
artifacts to the image, lock and client harness. Raw desktop logs, remote logs,
task output and fixture reports remain in the result directory even on failure.

The implementing assistant must open the original PNG files with `view_image`
and report what it actually sees. Programmatic assertions alone do not complete
the visual review. This test proves an integrated VS Code task; it does not claim
Playwright Test Explorer extension coverage.
