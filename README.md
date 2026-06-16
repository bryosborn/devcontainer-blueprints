# Dev Container Blueprints

A local-first Dev Container Template playground for reproducing a `cicd-common`-style development environment in smaller layers.

Planned shape:

```text
mcr.microsoft.com/devcontainers/base:3.0.1-ubuntu22.04
  -> base-dod image with Docker-outside-of-Docker only
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

## Static Checks

```bash
jq empty .devcontainer/devcontainer.json .devcontainer/devcontainer-lock.json
find scripts -type f -name '*.sh' -print0 | sort -z | xargs -0 -n1 bash -n
shellcheck -x scripts/*.sh scripts/lib/*.sh
find scripts -type f -name '*.sh' -printf '%m %p\n' | sort
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
