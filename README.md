# Dev Container Blueprints

Local-first Dev Container image and artifact workflows for rebuilding a reproducible development environment.

The current stack is:

```text
mcr.microsoft.com/devcontainers/base:3.0-ubuntu22.04
  -> base-dod        Docker-outside-of-Docker CLI image
  -> base-vscode     base-dod plus pinned VS Code Server
  -> base-toolchain  base-vscode plus offline-installed tools and extensions
```

## Quick Start

Prerequisites:

- Docker
- VS Code Dev Containers extension
- Dev Container CLI

Install the Dev Container CLI if needed:

```bash
npm install -g @devcontainers/cli
```

### 1. Online Machine: Download, Build, Test, Package

Run this on the machine that has internet access. It downloads all external artifacts, builds the local images, runs the smoke tests, and packages the artifact directory plus Docker image tars.

```bash
./scripts/prefetch-all.sh
./scripts/build-all.sh
./scripts/test-all.sh
./scripts/scan-images-trivy.sh
./scripts/package-artifacts.sh
```

The package step creates:

```text
artifacts-base-toolchain-0.2.0.tar.gz
artifacts-base-toolchain-0.2.0.tar.gz.sha256
```

### 2. Offline Build Test

Before moving into the fully disconnected workflow, test the packaged restore path on a machine or environment with Docker available and network access disabled for the image build/test steps. Copy the generated `.tar.gz` and `.sha256` files there, then run:

```bash
sha256sum -c artifacts-base-toolchain-0.2.0.tar.gz.sha256
tar -xzf artifacts-base-toolchain-0.2.0.tar.gz
./scripts/load-artifacts.sh
./src/base-toolchain/scripts/build-image.sh
./src/base-toolchain/scripts/test-image.sh
```

`build-image.sh` and `test-image.sh` run Docker builds/tests with `--network=none`, so this verifies that the packaged artifacts are enough to recreate and smoke-test `base-toolchain` without downloading anything during the build.

### 3. Disconnected Environment

Move the repo plus `artifacts-base-toolchain-0.2.0.tar.gz` and its `.sha256` file to the disconnected environment, then use the same restore commands:

```bash
sha256sum -c artifacts-base-toolchain-0.2.0.tar.gz.sha256
tar -xzf artifacts-base-toolchain-0.2.0.tar.gz
./scripts/load-artifacts.sh
./src/base-toolchain/scripts/build-image.sh
./src/base-toolchain/scripts/test-image.sh
```

For a disconnected Windows + WSL + VS Code setup, also run the WSL setup script from Windows PowerShell after unpacking the repo and artifacts:

```powershell
.\scripts\setup-wsl-artifacts.ps1 -Distro Ubuntu -WslRepoPath /home/me/devcontainer-blueprints
```

The WSL artifacts are transfer payloads for VS Code Remote development on the disconnected Windows host. They include the Linux VS Code Server archive, Windows-side Remote WSL and Dev Containers VSIX files, and the Dev Containers bootstrap container image used by `Clone Repository in Container Volume`.

The setup script expects Windows OpenSSH private keys under `%USERPROFILE%\.ssh` and requires the Windows `ssh-agent` service to be running. It calls `ssh-add` for every detected private key, so `ssh-add` should work from the same Windows environment before you run the setup script.

### Useful Narrow Commands

The module-level scripts are available when you want to work on one layer at a time. To package only the current artifact directory and configured image refs:

```bash
./scripts/package-artifacts.sh
```

That script saves `ARTIFACT_IMAGE_REFS` to `artifacts/docker-images/`, writes portable SHA256 files and `artifacts/manifest.json`, and creates `artifacts-<toolchain-name>-<version>.tar.gz` at the repo root.

To scan every configured project image in the host Docker image store and
generate a CycloneDX SBOM for each image:

```bash
./scripts/scan-images-trivy.sh
```

This requires `trivy` and writes JSON vulnerability reports, CycloneDX JSON
SBOMs, `vulnerability-summary.tsv`, and a combined `vulnerabilities.csv`
spreadsheet under `artifacts/trivy-output/`. The spreadsheet identifies the
container, CVE, combined fix-availability/severity value, days since
publication, status, remediation, scanner target, package class and ecosystem,
package path, installed/fixed versions, CVSS score, advisory details, PURL, and
image layer for each unique finding. The script checks all images in
`ARTIFACT_IMAGE_REFS` locally before scanning and does not pull a missing image
from a registry. It applies `config/trivy-ignore.rego` to suppress findings
attributed to the development-header packages `linux-libc-dev` and `libc6-dev`.
This affects vulnerability reporting only: both packages remain visible in the
SBOM inventory, and the policy does not remove them or remediate their CVEs.

To remove generated artifacts, temporary build workspaces, resolver dependencies, and packaged artifact bundles:

```bash
./scripts/clean.sh
```

Use `./scripts/clean.sh --docker-images` to also remove the repository's built and test Docker images. It does not force-remove images used by a container.

## Default Images

Online image defaults live in `config/docker.env`; WSL artifact defaults live in `config/wsl-artifacts.env`:

```text
UPSTREAM_BASE_IMAGE:  mcr.microsoft.com/devcontainers/base:3.0-ubuntu22.04
DOCKER_PLATFORM:      linux/amd64
BASE_IMAGE:           devcontainers/base-dod:0.2.0
BASE_VSCODE_IMAGE:    devcontainers/base-vscode:0.2.0
BASE_TOOLCHAIN_IMAGE: devcontainers/base-toolchain:0.2.0
BASE_VSCODE_VERSION:  1.136.1
ARTIFACT_IMAGE_REFS:  devcontainers/base-dod:0.2.0 devcontainers/base-vscode:0.2.0 devcontainers/base-toolchain:0.2.0
WSL_ARTIFACT_ROOT:    artifacts/wsl
```

The default uses the mutable `3.0-ubuntu22.04` tag so online preparation follows
the newest compatible 3.0.x base image. Rerun prefetch, build, test, and the
Trivy scan to consume upstream updates. Because its digest can change without a
Git configuration change, use a private `DOCKER_ENV_FILE` with a reviewed exact
patch tag when deterministic online rebuilds are required. Packaged Docker
image artifacts remain fixed for disconnected restores.

`DOCKER_PLATFORM` is the canonical image and artifact target. The shared
environment loader derives matching VS Code Server/extension, toolchain, and
Rust selectors, exports `DOCKER_DEFAULT_PLATFORM`, and the Docker workflows
also pass the platform explicitly. The supported targets are `linux/amd64` and
`linux/arm64`; the default is AMD64, so an ARM64 online preparation machine
uses Docker emulation to create AMD64 images.

The bootstrap `.devcontainer` uses the multi-architecture
`mcr.microsoft.com/devcontainers/base:3.0.3-ubuntu22.04` image so it runs
natively on both AMD64 and ARM64 hosts. This is separate from the project image
and artifact target controlled by `DOCKER_PLATFORM`.

The current artifact layout is intentionally single-target. Before changing
`DOCKER_PLATFORM`, clear generated state and regenerate it for the new target:

```bash
./scripts/clean.sh
./scripts/prefetch-all.sh
./scripts/build-all.sh
```

The WSL Windows-client setting remains independent of `DOCKER_PLATFORM`.
`WSL_SERVER_PLATFORMS` defaults to the selected container target but can be
overridden when the WSL distribution uses another supported server platform.

Scripts load `config/docker.env` by default. To use a private override, set `DOCKER_ENV_FILE`; relative paths are resolved from the repo root.

```bash
DOCKER_ENV_FILE=.env ./src/base-vscode/scripts/prefetch-server.sh
```

## What Each Layer Does

`base-dod` installs only Docker-outside-of-Docker on the upstream Microsoft base image. It disables Moby and keeps the Docker daemon out of the image.

DOD-related selections and observed versions:

```text
ghcr.io/devcontainers/features/docker-outside-of-docker:1.10.0
docker-ce-cli=29.8.0-1
docker-compose=5.5.1 (selected through dockerDashComposeVersion=latest)
docker-buildx-plugin=0.37.0-1
compose-switch=disabled
moby=false
```

The image metadata sets:

```text
remoteUser=vscode
updateRemoteUserUID=true
```

`base-vscode` extends `BASE_IMAGE` and installs a prefetched VS Code Server archive into:

```text
/home/vscode/.vscode-server/cli/servers/Stable-<commit>/server
/home/vscode/.vscode-server/bin/<commit>
```

`base-toolchain` extends `BASE_VSCODE_IMAGE` and installs local artifacts only:

```text
APT packages
Java and Maven
Node, npm, npx
Helm, kubectl, ORAS, yq
mongosh and MongoDB Database Tools
Rust nightly, rust-src, rustfmt, clippy
VS Code extensions
Python 3.12/3.13 with venv and pip entry points
```

The concrete tool versions in `config/toolchain.env` are refreshed deliberately;
the offline installers select those exact versions even when artifacts for other
versions or major lines remain in the local cache.
An empty configured hash skips strict pin validation during online prefetch, but
the prefetch scripts still calculate the downloaded artifact hash and store it
in module metadata and `CHECKSUMS` for the disconnected workflow.

## Artifact Workflows

VS Code Server:

```bash
./src/base-vscode/scripts/prefetch-server.sh
./src/base-vscode/scripts/test-server-install.sh
```

Server artifacts are written under `artifacts/vscode-server/`.

VS Code extensions:

```bash
./src/base-vscode/scripts/prefetch-extensions.sh
./src/base-vscode/scripts/test-extensions-install.sh
```

The extension resolver reads `config/vscode-extensions.txt`, downloads compatible VSIX files, expands dependencies and extension packs, validates hashes, and writes:

```text
artifacts/vscode-extensions/vscode-extensions.lock.json
```

WSL bootstrap artifacts:

```bash
./src/wsl-artifacts/scripts/prefetch.sh
./src/wsl-artifacts/scripts/test-artifacts.sh
```

The WSL workflow reads `config/wsl-artifacts.env`, downloads the matching Linux VS Code Server archive and Windows-side Remote WSL and Dev Containers VSIX files, then writes:

```text
artifacts/wsl/manifest.json
```

If its resolver dependency directory is absent, the workflow restores the locked
Node dependencies with `npm ci --no-audit --no-fund`; this avoids waiting on the
optional npm vulnerability-audit service during prefetch.

These files are not installed into `base-toolchain`. They are copied to the disconnected Windows host so VS Code can bootstrap Remote WSL, install the needed extensions, and avoid pulling the Dev Containers bootstrap image from the network.

The workflow also builds the Dev Containers extension's default bootstrap container image for `Clone Repository in Container Volume` from that extension's bundled `bootstrap.Dockerfile`, then saves the image tar under:

```text
artifacts/wsl/docker-images/
```

On the disconnected Windows host, run the setup script to add local SSH keys to `ssh-agent`, load the saved bootstrap container image, install the VSIX files, set `dev.containers.bootstrapImage` with image pulling disabled, and optionally trigger the WSL-side server install:

```powershell
.\scripts\setup-wsl-artifacts.ps1 -Distro Ubuntu -WslRepoPath /home/me/devcontainer-blueprints
```

The script expects OpenSSH private keys under `%USERPROFILE%\.ssh` and a running Windows `ssh-agent` service. It calls `ssh-add` for each detected private key; if `ssh-add` does not work in Windows PowerShell, fix that first. If keys or the agent are missing, the script stops with a message before trying the VS Code setup.

APT packages:

```bash
./src/apt-artifacts/scripts/prefetch.sh
./src/apt-artifacts/scripts/test-install.sh
```

The APT workflow writes a local file-backed apt repo under `artifacts/apt/`.

Toolchain modules:

```bash
./src/tool-artifacts/scripts/prefetch-all.sh
./src/tool-artifacts/scripts/test-all.sh
```

Single-module entry points:

```bash
./src/tool-artifacts/java-maven/scripts/prefetch.sh
./src/tool-artifacts/node/scripts/prefetch.sh
./src/tool-artifacts/cli-tools/scripts/prefetch.sh
./src/tool-artifacts/mongodb/scripts/prefetch.sh
./src/tool-artifacts/rust/scripts/prefetch.sh
```

Tool versions and hashes live in `config/toolchain.env`. Node currently tracks the
latest 24.x release and Helm tracks the latest 3.x release. Empty hash fields are
allowed while exploring; filled hashes are strict verification pins.

Rust prefetch runs the target `rustup-init` binary. If the online host and the
selected target differ, the Rust script creates that cache in a target-platform
Docker build instead of trying to execute a foreign-architecture binary on the
host.

The composed `base-toolchain` Dockerfile installs each module in its own layer. The default build enables every module, and each one can be turned off with a `BASE_TOOLCHAIN_INSTALL_*` setting in `config/docker.env` or a private `DOCKER_ENV_FILE`:

```text
BASE_TOOLCHAIN_INSTALL_APT
BASE_TOOLCHAIN_INSTALL_PYTHON_PIP
BASE_TOOLCHAIN_INSTALL_JAVA_MAVEN
BASE_TOOLCHAIN_INSTALL_NODE
BASE_TOOLCHAIN_INSTALL_CLI_TOOLS
BASE_TOOLCHAIN_INSTALL_MONGODB_TOOLS
BASE_TOOLCHAIN_INSTALL_RUST
BASE_TOOLCHAIN_INSTALL_VSCODE_EXTENSIONS
```

## Build Notes

Docker builds that consume artifacts run with `--network=none`.

The composed toolchain build uses named BuildKit contexts for:

```text
artifacts/apt
artifacts/toolchain
artifacts/vscode-extensions
```

Those directories are mounted during install steps. Raw downloaded archives are not copied into permanent image layers.

Dockerfiles intentionally use the built-in BuildKit Dockerfile frontend. Avoid adding `# syntax=docker/dockerfile:...` unless the matching frontend image is also packaged and loaded, because BuildKit resolves that image before the disconnected build starts.

## Static Checks

```bash
jq empty .devcontainer/devcontainer.json .devcontainer/devcontainer-lock.json
jq empty src/base-vscode/devcontainer-template.json src/base-vscode/.devcontainer/devcontainer.json src/base-toolchain/devcontainer-template.json src/base-toolchain/.devcontainer/devcontainer.json
find scripts src/base-vscode/scripts src/base-toolchain/scripts src/wsl-artifacts/scripts src/apt-artifacts/scripts src/tool-artifacts -type f -name '*.sh' -print0 | sort -z | xargs -0 -n1 bash -n
find scripts src/base-vscode/scripts src/base-toolchain/scripts src/wsl-artifacts/scripts src/apt-artifacts/scripts src/tool-artifacts -type f -name '*.sh' -print0 | sort -z | xargs -0 shellcheck -x
npm run test:vscode-extensions
find scripts src/base-vscode/scripts src/base-toolchain/scripts src/wsl-artifacts/scripts src/apt-artifacts/scripts src/tool-artifacts -type f -name '*.sh' -printf '%m %p\n' | sort
```

## Optional Registry Override

The default workflow uses the host Docker daemon image store and does not need a registry.

To test push/pull behavior against a registry you already manage, create a private env file such as `docker.local.env`, override `REGISTRY` and the derived image refs, and run scripts with it:

```bash
DOCKER_ENV_FILE=docker.local.env ./scripts/pull-upstream-base-image.sh
DOCKER_ENV_FILE=docker.local.env ./scripts/build-base-dod.sh
```

## Concepts

This repo keeps these separate:

```text
Template ID  = logical Dev Container Template identity
Docker image = reusable base layer stored by Docker
Feature      = Dev Container Feature applied to an image/template
Image store  = ordinary local Docker builds and tags
Registry     = optional remote or local push/pull service
```

`REGISTRY` is an image prefix. It can be a local namespace such as `devcontainers`, or a registry host/path such as `localhost:5001/devcontainers`.
