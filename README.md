# Dev Container Blueprints

A local-first, offline-capable Dev Container Template repository.

This repository demonstrates a minimal pattern:

```text
online prefetch phase
  -> local artifact cache
  -> local Docker registry
  -> offline Docker build
  -> local Dev Container Template
```

## Concepts

This repo separates three ideas:

```text
Template ID  = logical Dev Container Template identity
Docker image = reusable build layer
Artifacts    = locally cached install inputs
Registry     = where Docker images are pushed and pulled
```

Example:

```text
Template ID:       simple-dev
Template path:     src/simple-dev
Base image:        localhost:5000/devcontainers/dev-base:0.1.0
Mirrored upstream: localhost:5000/upstream/devcontainers/base:ubuntu
```

The template ID does not need to match the Docker image name.

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

The bootstrap devcontainer uses:

```text
mcr.microsoft.com/devcontainers/base:ubuntu
```

It also includes Docker-outside-of-Docker and Node so the container can run Docker commands through the host Docker daemon and install/use the Dev Container CLI.

## One-Time Local Registry Start

```bash
./scripts/start-local-registry.sh
```

This starts a local Docker registry at:

```text
localhost:5000
```

## Online Preparation

Run this while connected to the internet:

```bash
./scripts/mirror-base-images.sh
./scripts/prefetch-artifacts.sh
```

This does two things:

1. Pulls the upstream Microsoft Dev Container base image and pushes it into the local registry.
2. Downloads required `.deb` package artifacts into `artifacts/apt/debs/`.

## Build the Base Image Online

```bash
./scripts/build-images.sh
```

This builds:

```text
localhost:5000/devcontainers/dev-base:0.1.0
```

## Push the Base Image to the Local Registry

```bash
./scripts/push-images.sh
```

## Test Offline Build

After prefetching artifacts and mirroring the upstream base image, test the offline build:

```bash
./scripts/build-images-offline.sh
```

This uses:

```bash
docker build --network=none
```

If this succeeds, the image build is not reaching out to the internet.

## Static Checks

```bash
jq empty .devcontainer/devcontainer.json src/simple-dev/devcontainer-template.json src/simple-dev/.devcontainer/devcontainer.json
for script in scripts/*.sh; do bash -n "$script"; done
shellcheck -x scripts/*.sh
find scripts -maxdepth 1 -type f -name '*.sh' -printf '%m %p\n' | sort
```

## Test the `simple-dev` Template

```bash
./scripts/test-simple-dev.sh
```

This creates a temporary test workspace, applies the `src/simple-dev` template, and builds the resulting dev container.

Some Dev Container CLI versions only accept OCI template references for `devcontainer templates apply`.
The test script first tries the CLI path-based apply, then falls back to applying the local template files directly.

## Typical Full Local Workflow

```bash
./scripts/start-local-registry.sh
./scripts/mirror-base-images.sh
./scripts/prefetch-artifacts.sh
./scripts/build-images.sh
./scripts/push-images.sh
./scripts/build-images-offline.sh
./scripts/test-simple-dev.sh
```

## Retargeting to Nexus Later

Copy `config/registry.nexus.example.env` to a real local file and edit it.

Example future image target:

```text
nexus.company.com/repository/docker-dev/devcontainers/dev-base:0.1.0
```

The template ID remains:

```text
simple-dev
```

Only registry/image references change.
