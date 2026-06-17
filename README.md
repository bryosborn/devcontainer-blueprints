# Dev Container Blueprints

Local-first Dev Container image and artifact workflows for rebuilding a smaller `cicd-common`-style development environment.

The current stack is:

```text
mcr.microsoft.com/devcontainers/base:3.0.1-ubuntu22.04
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

Prepare, build, test, and package everything from a connected machine:

```bash
./scripts/prefetch-all.sh
./scripts/build-all.sh
./scripts/test-all.sh
./scripts/package-artifacts.sh
```

Move the generated `artifacts-*.tar.gz` and matching `.sha256` file to the disconnected machine, then run:

```bash
sha256sum -c artifacts-base-toolchain-0.1.0.tar.gz.sha256
tar -xzf artifacts-base-toolchain-0.1.0.tar.gz
./scripts/load-artifacts.sh
./src/base-toolchain/scripts/build-image.sh
./src/base-toolchain/scripts/test-image.sh
```

The module-level scripts are still available when you want to work on one layer at a time.

Package only the current artifact directory and configured image refs:

```bash
./scripts/package-artifacts.sh
```

That script saves `ARTIFACT_IMAGE_REFS` to `artifacts/docker-images/`, writes portable SHA256 files and `artifacts/manifest.json`, and creates `artifacts-<toolchain-name>-<version>.tar.gz` at the repo root.

## Default Images

Defaults live in `docker.env`:

```text
UPSTREAM_BASE_IMAGE:  mcr.microsoft.com/devcontainers/base:3.0.1-ubuntu22.04
BASE_IMAGE:           devcontainers/base-dod:0.1.0
BASE_VSCODE_IMAGE:    devcontainers/base-vscode:0.1.0
BASE_TOOLCHAIN_IMAGE: devcontainers/base-toolchain:0.1.0
BASE_VSCODE_VERSION:  1.124.2
ARTIFACT_IMAGE_REFS:  devcontainers/base-dod:0.1.0 devcontainers/base-vscode:0.1.0
```

Scripts load `docker.env` by default. To use a private override, set `DOCKER_ENV_FILE`; relative paths are resolved from the repo root.

```bash
DOCKER_ENV_FILE=.env ./src/base-vscode/scripts/prefetch-server.sh
```

## What Each Layer Does

`base-dod` installs only Docker-outside-of-Docker on the upstream Microsoft base image. It disables Moby and keeps the Docker daemon out of the image.

Pinned DOD-related values:

```text
ghcr.io/devcontainers/features/docker-outside-of-docker:1.10.0
docker-ce-cli=29.5.3-1
docker-compose=2.40.3
docker-buildx-plugin=0.34.1-1
compose-switch=1.0.5
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

Tool versions and hashes live in `config/toolchain.env`. Empty hash fields are allowed while exploring; filled hashes are strict verification pins.

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
find scripts src/base-vscode/scripts src/base-toolchain/scripts src/apt-artifacts/scripts src/tool-artifacts -type f -name '*.sh' -print0 | sort -z | xargs -0 -n1 bash -n
find scripts src/base-vscode/scripts src/base-toolchain/scripts src/apt-artifacts/scripts src/tool-artifacts -type f -name '*.sh' -print0 | sort -z | xargs -0 shellcheck -x
jq empty src/base-vscode/devcontainer-template.json src/base-vscode/.devcontainer/devcontainer.json src/base-toolchain/devcontainer-template.json src/base-toolchain/.devcontainer/devcontainer.json
npm run test:vscode-extensions
./src/base-toolchain/scripts/compare-cicd-common.sh
find scripts src/base-vscode/scripts src/base-toolchain/scripts src/apt-artifacts/scripts src/tool-artifacts -type f -name '*.sh' -printf '%m %p\n' | sort
```

## Optional Registry Workflow

The default workflow uses the host Docker daemon image store and does not need a registry.

To test push/pull behavior, start the local registry on port `5001`:

```bash
./scripts/start-local-registry.sh
```

Then copy the example config and run scripts with it:

```bash
cp docker.local.example.env docker.local.env
DOCKER_ENV_FILE=docker.local.env ./scripts/pull-upstream-base-image.sh
DOCKER_ENV_FILE=docker.local.env ./scripts/build-base-dod.sh
```

Port `5001` is used because host port `5000` is commonly occupied by AirPlay Receiver on macOS.

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
