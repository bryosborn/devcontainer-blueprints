# Dev Container Blueprints

A local-first Dev Container Template playground for reproducing a `cicd-common`-style development environment in smaller layers.

Planned shape:

```text
mcr.microsoft.com/devcontainers/base:3.0.1-ubuntu22.04
  -> base-dod image with Docker-outside-of-Docker only
  -> base-vscode template image with a pinned VS Code Server payload
```

## Concepts

This repo separates these ideas:

```text
Template ID  = logical Dev Container Template identity
Docker image = reusable base layer stored by Docker
Feature      = Dev Container Feature applied to an image/template
Docker daemon image store = where ordinary local builds and tags live
Registry     = optional remote or local service for pushed/pulled images
```

Current/default coordinates live in `docker.env`:

```text
REGISTRY:            devcontainers
BASE_IMAGE_NAME:     base-dod
BASE_IMAGE_VERSION:  0.1.0
UPSTREAM_BASE_IMAGE: mcr.microsoft.com/devcontainers/base:3.0.1-ubuntu22.04
BASE_IMAGE:          devcontainers/base-dod:0.1.0
BASE_VSCODE_IMAGE:   devcontainers/base-vscode:0.1.0
BASE_VSCODE_VERSION: 1.124.2
```

`REGISTRY` is used as an image prefix. For local daemon-only builds it can be just a namespace like `devcontainers`; for a registry workflow it can include a host and path like `localhost:5001/devcontainers`.

The `base-dod` image contains only Docker-outside-of-Docker on top of the upstream base image, installed by the Dev Container Feature installer, with Moby disabled:

```text
ghcr.io/devcontainers/features/docker-outside-of-docker:1.10.0
docker-ce-cli=29.5.3-1
docker-compose=2.40.3
docker-buildx-plugin=0.34.1-1
moby=false
feature installDockerComposeSwitch=false
compose-switch=1.0.5
```

These are the Docker-related runtime versions observed in the DOD container when the feature was allowed to install the latest packages. The Dev Container Feature supports the Docker CLI version pin directly. Its Compose option is limited to `none`, `latest`, `v1`, or `v2`, and its exact Buildx pin only applies to the Moby package path, so `docker.env` records the observed Compose and Buildx versions even though the DOD feature does not expose exact Docker CE package pins for those two installs. The upstream feature installs compose-switch as `latest`, so the build script disables that path and adds pinned compose-switch `1.0.5` in a final image layer.

The image metadata also sets:

```text
remoteUser=vscode
updateRemoteUserUID=true
```

Scripts default to `docker.env` in the repo root. To use a private override file, set `DOCKER_ENV_FILE`; relative paths are resolved from the repo root.

## Prerequisites

Install:

- Docker
- VS Code Dev Containers extension
- Dev Container CLI

The Dev Container CLI can be installed with npm:

```bash
npm install -g @devcontainers/cli
```

## Bootstrap Dev Container

This repo includes its own `.devcontainer` folder so it can be opened in VS Code as a development container.

The bootstrap devcontainer uses the same base family as the `cicd-common` reference:

```text
mcr.microsoft.com/devcontainers/base:3.0.1-ubuntu22.04
```

It also includes Docker-outside-of-Docker and Node so the container can run Docker commands through the host Docker daemon and install/use the Dev Container CLI.

## Current Scripts

Pull the configured upstream base image:

```bash
./scripts/pull-upstream-base-image.sh
```

Build the DOD-only base image:

```bash
./scripts/build-base-dod.sh
```

The build script applies the configured DOD feature to `UPSTREAM_BASE_IMAGE` and tags the result as `BASE_IMAGE`.

Smoke test the DOD-only base image:

```bash
./scripts/test-base-dod.sh
```

Prefetch the configured VS Code Server archive:

```bash
./src/base-vscode/scripts/prefetch-server.sh
```

The prefetch script writes artifacts under:

```text
artifacts/vscode-server/stable/<commit>/<server-platform>/
```

Build a base VS Code image from the template in `src/base-vscode`:

```bash
./src/base-vscode/scripts/build-template.sh
```

The template extends `BASE_IMAGE`, copies the prefetched artifact into the build context, and installs the configured VS Code Server archive into both known VS Code Server layouts:

```text
/home/vscode/.vscode-server/cli/servers/Stable-${BASE_VSCODE_COMMIT}/server
/home/vscode/.vscode-server/bin/${BASE_VSCODE_COMMIT}
```

The default VS Code version comes from `docker.env`. To build for a different VS Code version, copy `docker.env` to a private ignored env file, set `BASE_VSCODE_VERSION`, prefetch that version, and run the build script with `DOCKER_ENV_FILE`. Set `BASE_VSCODE_COMMIT` only when you need an exact commit override.

Prove the installer Dockerfile path without network access:

```bash
./src/base-vscode/scripts/test-server-install.sh
```

Smoke test the base VS Code image without network access:

```bash
./src/base-vscode/scripts/test-template.sh
```

## VS Code Extension Artifact Workflow

`config/vscode-extensions.txt` captures the initial extension IDs adapted from `cicd-common/extensions.txt`. The prefetch script resolves compatible versions for the configured VS Code Server metadata, expands dependencies and extension packs, downloads VSIX artifacts, validates each VSIX, and writes a lockfile:

```bash
./src/base-vscode/scripts/prefetch-extensions.sh
```

The generated lockfile is written to:

```text
artifacts/vscode-extensions/vscode-extensions.lock.json
```

The lockfile records exact versions, target platform, SHA256 hashes, install order, host-only extensions, built-in VS Code dependencies, and warnings. VSIX files are ignored by git.

Prove the VS Code Server plus extension install path without network access:

```bash
./src/base-vscode/scripts/test-extensions-install.sh
```

The test builds with `docker build --network=none`, installs the prefetched VS Code Server archive, installs only local VSIX files from the lockfile, and verifies the installed extension list with `code-server --list-extensions --show-versions`.

## APT Artifact Workflow

`src/apt-artifacts/apt-packages.txt` captures the APT package roots adapted from the `cicd-common` Dockerfile. The prefetch script resolves those package roots against the configured target image and writes a local file-backed apt repo under `artifacts/apt/`:

```bash
./src/apt-artifacts/scripts/prefetch.sh
```

The artifact repo contains `.deb` files plus `Packages`, `Packages.gz`, and checksums. The install helper then points apt at that local repo during a Docker build.

Prove the install path without network access:

```bash
./src/apt-artifacts/scripts/test-install.sh
```

## Toolchain Artifact Workflow

`config/toolchain.env` centralizes the versions adapted from the `cicd-common` toolchain Dockerfile. Hash fields are first-class but optional: leave a hash empty to download the artifact and record the observed hash in generated metadata, or fill it in to make prefetch fail on a mismatch.

The first toolchain modules are split by install shape:

```text
src/tool-artifacts/java-maven/
src/tool-artifacts/node/
src/tool-artifacts/cli-tools/
```

Prefetch all current modules:

```bash
./src/tool-artifacts/scripts/prefetch-all.sh
```

Or prefetch a single module:

```bash
./src/tool-artifacts/java-maven/scripts/prefetch.sh
./src/tool-artifacts/node/scripts/prefetch.sh
./src/tool-artifacts/cli-tools/scripts/prefetch.sh
```

Artifacts are written under `artifacts/toolchain/` and ignored by git. Each module has an offline Docker build test that bind-mounts the artifact directory with BuildKit, so raw downloaded archives are available during installation without being copied into a permanent image layer.

Run all current offline install tests:

```bash
./src/tool-artifacts/scripts/test-all.sh
```

Or test a single module:

```bash
./src/tool-artifacts/java-maven/scripts/test-install.sh
./src/tool-artifacts/node/scripts/test-install.sh
./src/tool-artifacts/cli-tools/scripts/test-install.sh
```

## Base Toolchain Image

`src/base-toolchain` composes the current prepared pieces into one image:

```text
BASE_VSCODE_IMAGE
  -> APT artifacts
  -> Java/Maven artifacts
  -> Node artifacts
  -> CLI tool artifacts
  -> VS Code extension artifacts
```

Build it after the artifact prefetch steps have completed:

```bash
./src/base-toolchain/scripts/build-image.sh
```

The build uses `docker build --network=none` and named BuildKit contexts for `artifacts/apt`, `artifacts/toolchain`, and `artifacts/vscode-extensions`. Those artifact directories are mounted only during install steps; the raw archives are not copied into permanent image layers.

Smoke test the composed image:

```bash
./src/base-toolchain/scripts/test-image.sh
```

The smoke test verifies Java/Maven, Node/npm/npx, Helm, kubectl, ORAS, yq, VS Code Server, the installed VS Code extensions, Docker CLI-only behavior, and Python `3.12`/`3.13` plus `venv` availability. Global `pip` for Python `3.12`/`3.13` is not assumed by this layer.

## Static Checks

```bash
jq empty .devcontainer/devcontainer.json .devcontainer/devcontainer-lock.json
find scripts src/base-vscode/scripts src/base-toolchain/scripts src/apt-artifacts/scripts src/tool-artifacts -type f -name '*.sh' -print0 | sort -z | xargs -0 -n1 bash -n
find scripts src/base-vscode/scripts src/base-toolchain/scripts src/apt-artifacts/scripts src/tool-artifacts -type f -name '*.sh' -print0 | sort -z | xargs -0 shellcheck -x
jq empty src/base-vscode/devcontainer-template.json src/base-vscode/.devcontainer/devcontainer.json src/base-toolchain/devcontainer-template.json src/base-toolchain/.devcontainer/devcontainer.json
npm run test:vscode-extensions
./src/base-vscode/scripts/test-server-install.sh
find scripts src/base-vscode/scripts src/base-toolchain/scripts src/apt-artifacts/scripts src/tool-artifacts -type f -name '*.sh' -printf '%m %p\n' | sort
```

## Optional Registry Workflow

The default workflow does not need a registry. If you want to test push/pull behavior, start a local registry on port `5001`:

```bash
./scripts/start-local-registry.sh
```

Copy the local-registry example to an ignored local override:

```bash
cp docker.local.example.env docker.local.env
```

Then run scripts with the override. This pulls the upstream Microsoft base image into the host daemon, builds `BASE_IMAGE`, and pushes that built image to the local registry:

```bash
DOCKER_ENV_FILE=docker.local.env ./scripts/pull-upstream-base-image.sh
DOCKER_ENV_FILE=docker.local.env ./scripts/build-base-dod.sh
```

Port `5001` is used because host port `5000` is commonly occupied by AirPlay Receiver on macOS.
