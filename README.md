# Wolfi image blueprints

Build a reusable CI image and a development image for the same codebase from
independent YAML configurations. Each configuration produces one image.

| Configuration | Output | Defaults |
| --- | --- | --- |
| [`config/wolfi-ci.yaml`](config/wolfi-ci.yaml) | `devcontainers/wolfi-ci:0.1.0` | Build tools, everyday utilities, Kaniko, root shell for GitLab jobs |
| [`config/wolfi-dev.yaml`](config/wolfi-dev.yaml) | `devcontainers/wolfi-dev:0.1.0` | Same build tools/utilities, `vscode` user, VS Code Server, Docker socket access |

Docker, VS Code, Kaniko, Playwright, and individual build/utility selections are
optional. Comment out a selection to disable it. Both examples target `linux/amd64`; `linux/arm64` is
also supported. Local image tags live in the host Docker daemon image store.

## Getting started

Open this repository in its Dev Container with Docker and VS Code's Dev
Containers extension available on the host. The connected Wolfi bootstrap
provides the preparation tools independently of the generated images. It uses
the host architecture and requires host Docker socket access.

Alternatively, prepare on Linux with Docker/BuildKit, Node/npm, Python 3.10+, jq,
GNU coreutils/tar, gzip, Git, and the Dev Containers CLI. Full checks also use
ShellCheck, Trivy, passwordless sudo, and `setpriv`. Resolving Kaniko also requires
Cosign 3.1.3, supplied by the bootstrap.

```bash
npm ci
./scripts/wolfi.sh update-lock --config config/wolfi-ci.yaml
./scripts/wolfi.sh update-lock --config config/wolfi-dev.yaml
```

Review the generated companion locks, then build, test, and scan each profile:

```bash
./scripts/wolfi.sh prefetch --config config/wolfi-ci.yaml
./scripts/wolfi.sh build --config config/wolfi-ci.yaml
./scripts/wolfi.sh test --config config/wolfi-ci.yaml
./scripts/wolfi.sh scan --config config/wolfi-ci.yaml

./scripts/wolfi.sh prefetch --config config/wolfi-dev.yaml
./scripts/wolfi.sh build --config config/wolfi-dev.yaml
./scripts/wolfi.sh test --config config/wolfi-dev.yaml
./scripts/wolfi.sh scan --config config/wolfi-dev.yaml
```

`update-lock` resolves mutable selectors. Subsequent commands require the
matching lock and verified artifacts. Image installation and runtime smokes
run with networking disabled. `test --quick` retains runtime/server checks
while reducing the identity matrix and skipping disposable VSIX installation.

## Configuration

A minimal configuration is:

```yaml
schemaVersion: 2
image:
  reference: devcontainers/my-ci:0.1.0
  platform: linux/amd64
artifacts:
  root: artifacts/my-ci
wolfi:
  baseImage: cgr.dev/chainguard/wolfi-base:latest
  repositories:
    main: https://apk.cgr.dev/chainguard
    extra: https://apk.cgr.dev/extra-packages
```

It contains the small shell/utility baseline and runs as root. Add optional
sections from either example to select languages, Docker tooling, or VS Code.
Each YAML needs its own non-overlapping artifact root. There is no YAML
inheritance or fixed CI/dev role in the builder.

See [the configuration and security guide](docs/wolfi.md) for optionality,
locking, runtime behavior, scans, and architecture details.
The [Ubuntu/Wolfi software comparison](docs/software-comparison.md) lists the
previous Ubuntu image's software beside the current Wolfi CI/dev inventories.

## Using the images

For development, a consuming `.devcontainer/devcontainer.json` can contain:

```json
{
  "name": "Project development",
  "image": "devcontainers/wolfi-dev:0.1.0"
}
```

The image carries its Dev Container user and optional socket metadata. The VSIX
archive remains uninstalled in the user's home. After connecting, run
`~/install-vscode-extensions.sh` when the profile includes extensions.

GitLab application jobs use the CI image without a Docker socket, daemon, or
privileged container. Compile/test and image packaging run in separate jobs,
passing application outputs through GitLab artifacts. The [GitLab example](examples/gitlab-ci.yml)
accepts two approved digest-pinned image inputs: select the same Kaniko-enabled
Wolfi CI digest for both, or use a dedicated shell-capable Kaniko image for
packaging. Credentials stay in GitLab configuration. Include the example with
explicit `ci-image` and `kaniko-image` inputs; mandatory inputs are checked at
pipeline creation ([GitLab inputs](https://docs.gitlab.com/ci/inputs/)).
Producing reusable Wolfi images locally still uses Docker/BuildKit.

## Choosing optional software

The examples have parallel blocks and a shared editor schema. `build` contains
native C/C++ tools and language runtimes; `utilities` offers reviewed native
Wolfi packages. Curl, SSH client/key tools, ZIP tools, less, procps and findutils
are enabled in both. DNS/network diagnostics are commented out because they
add dependencies. There is no broad networking bundle and no arbitrary Alpine
package mixing. The catalog guides compatible choices; fresh raw scans still
determine CVE acceptance, including unfixed findings.

Enable browser testing with `playwright: true`, or pin
`playwright: {version: "1.63.0"}`. Both examples leave it disabled. It requires
`build.node` and `build.npm`, installs matched official Chromium and headless-shell
binaries plus signed Wolfi libraries and focused fonts, and sets
`PLAYWRIGHT_BROWSERS_PATH`. Declare the **same exact** `@playwright/test` version
in your application and retain its npm lock/dependency cache. Screenshots,
traces and headed tests through `xvfb-run` are supported; video/FFmpeg, Firefox
and WebKit are excluded. Wolfi is not an officially supported Playwright OS;
this repository verifies its selected combination. See [browser verification](docs/wolfi.md#playwright).

`kaniko: {version: "1.28.4"}` selects the maintained osscontainertools fork.
`kaniko-build` enforces its filesystem preservation/cleanup flags and requires
root. Run it in a **disposable job**, with context on a mount or under `/kaniko`.
It temporarily replaces the job container's filesystem; interrupted cleanup
cannot guarantee restoration. Never run it inside your live editor container.
The root CI default supports this workflow. Root is not required for compilation
itself; omit Kaniko and configure a named user if your runner enforces non-root.
The intended Kubernetes runner permits UID 0 with `privileged=false`; actual
cluster policy and registry access must be checked during deployment.

ClamAV remains commented out until all selected signed packages resolve to
`1.5.4-r0` or newer and pass build/test/raw scanning. The retained `1.5.2-r7`
package had seven unique High CVEs. No ignore or vendor fallback is used, and
selected software is never silently disabled to obtain a passing scan.

## Offline transfer and cleanup

```bash
./scripts/wolfi.sh package --config config/wolfi-ci.yaml
sha256sum -c artifacts-wolfi-ci-linux-amd64.tar.gz.sha256
# Transfer the repository, bundle, and checksum to the disconnected machine.
tar -xzf artifacts-wolfi-ci-linux-amd64.tar.gz
./scripts/wolfi.sh load --config config/wolfi-ci.yaml
./scripts/wolfi.sh build --config config/wolfi-ci.yaml
./scripts/wolfi.sh test --config config/wolfi-ci.yaml
```

Repeat for the dev profile as needed. Each bundle contains its configuration,
lock, exact base/APK/vendor supply, and one output image. Loading validates
hashes and image identity before importing Docker images.

```bash
./scripts/wolfi.sh clean --config config/wolfi-ci.yaml --dry-run
./scripts/wolfi.sh clean --config config/wolfi-ci.yaml
./scripts/wolfi.sh clean --config config/wolfi-ci.yaml --docker-images
```

Cleanup targets the selected profile's artifacts and bundle. Docker image
removal is opt-in and non-forced.

## Repository checks

```bash
npm test
find scripts src/wolfi -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
find scripts src/wolfi -type f -name '*.sh' -print0 | xargs -0 shellcheck -x
```

Ubuntu, APT, WSL artifact setup, fixed intermediate output images, and the
Ubuntu/Wolfi comparison workflow have been retired on this branch. Schema-v1
configs and commands are replaced by the explicit profile interface above.
