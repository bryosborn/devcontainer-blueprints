# AGENTS.md

This repository is a local-first Dev Container Template playground. Future agents should read this file before making changes, then update the learned lessons log at the bottom when they discover something that would help the next session.

## Project Goal

Build a boring, minimal skeleton that proves this planned flow:

```text
local template
  -> cicd-common-style upstream base image
  -> base-dod image with Docker-outside-of-Docker only
  -> usable scratch devcontainer
```

Keep the concepts separate:

```text
Template ID  = logical Dev Container Template identity
Docker image = reusable base layer stored by Docker
Feature      = Dev Container Feature applied to an image/template
Docker daemon image store = where ordinary local builds and tags live
Registry     = optional remote or local service for pushed/pulled images
```

Current concrete names:

```text
REGISTRY:            devcontainers
BASE_IMAGE_NAME:     base-dod
BASE_IMAGE_VERSION:  0.1.0
UPSTREAM_BASE_IMAGE: mcr.microsoft.com/devcontainers/base:3.0.1-ubuntu22.04
BASE_IMAGE:          devcontainers/base-dod:0.1.0
Default config:      docker.env
```

## Repository Map

- `README.md`: User-facing workflow and explanation.
- `.devcontainer/`: Bootstrap development container for working on this repo.
- `docker.env`: Default host Docker daemon image coordinates.
- `docker.local.example.env`: Optional local-registry env example; copy to ignored `docker.local.env`.
- `scripts/pull-upstream-base-image.sh`: Pulls `UPSTREAM_BASE_IMAGE`.
- `scripts/build-base-dod.sh`: Builds `BASE_IMAGE` with the DOD feature and `moby=false`.
- `scripts/test-base-dod.sh`: Smoke tests the DOD base image.
- `scripts/lib/env.sh`: Shared env-file loading, required-variable checks, and image-ref helpers.
- `scripts/start-local-registry.sh`: Optional helper for registry experiments.
- `cicd-common/`: Ignored reference extraction from `cicd-common.zip`; do not edit or stage.

## Design Rules

- Keep this first version minimal.
- Do not add GitHub Actions, GHCR publishing, custom Dev Container Features, Docker-in-Docker, Compose services, language stacks, or enterprise registry plumbing yet.
- The target base family should match the `cicd-common` reference: `mcr.microsoft.com/devcontainers/base:3.0.1-ubuntu22.04`.
- `base-dod` is the built image containing only Docker-outside-of-Docker installed through the Dev Container Feature installer.
- The Docker-outside-of-Docker feature should use `moby=false`.
- The final DOD image should include compose-switch pinned by `DOD_COMPOSE_SWITCH_VERSION`. The upstream Docker-outside-of-Docker feature installs compose-switch as `latest`, so keep `DOD_FEATURE_INSTALL_DOCKER_COMPOSE_SWITCH=false` and add the pinned switch in the build script's final image layer.
- `docker.env` records the Docker runtime versions observed from the DOD feature when it installed latest packages: Docker CLI `29.5.3-1`, Compose `2.40.3`, and Buildx `0.34.1-1`. The feature supports the Docker CLI pin directly; exact Compose and Docker CE Buildx pins are reference values because the feature schema does not expose exact Docker CE package version options for them.
- The DOD base image metadata should set `remoteUser: vscode` and `updateRemoteUserUID: true`.
- The default local workflow should use the host Docker daemon image store, not an assumed local registry.
- Registry workflows are opt-in through `DOCKER_ENV_FILE`.
- `REGISTRY` is treated as an image prefix, so it may include a namespace, registry host, or registry host plus path.
- The optional local registry workflow should copy `docker.local.example.env` to ignored `docker.local.env` and run scripts with `DOCKER_ENV_FILE=docker.local.env`.
- Personal `.env` and `*.local.env` files are ignored by git and can be used with `DOCKER_ENV_FILE`.
- The template ID does not need to match any Docker image name.

## Important Caveats

- On the observed host path, port `5000` answered as Apple AirTunes/AirPlay rather than Docker Registry, so the optional local registry example uses port `5001`.
- `cicd-common/` is reference-only and ignored by git. Read it for context, but do not modify it as part of repo changes.

## Usual Commands

Static checks:

```bash
jq empty .devcontainer/devcontainer.json .devcontainer/devcontainer-lock.json
find scripts -type f -name '*.sh' -print0 | sort -z | xargs -0 -n1 bash -n
shellcheck -x scripts/*.sh scripts/lib/*.sh
find scripts -type f -name '*.sh' -printf '%m %p\n' | sort
```

Current online preparation:

```bash
./scripts/pull-upstream-base-image.sh
./scripts/build-base-dod.sh
./scripts/test-base-dod.sh
```

## Change Hygiene

- Preserve unrelated user changes. Check `git status --short --branch` before edits.
- Keep scripts executable after edits: `chmod +x scripts/*.sh`.
- Prefer small, direct changes over new abstractions.
- Update `README.md` when changing user-facing workflow.
- Update this file when changing agent-facing workflow, caveats, or learned lessons.

## Learned Lessons Log

Append new entries here as work proceeds. Keep each entry dated and concise. Use this format:

```text
YYYY-MM-DD - Finding: ...
YYYY-MM-DD - Decision: ...
YYYY-MM-DD - Caveat: ...
```

Current lessons:

- 2026-06-16 - Finding: `shellcheck` is available in the current bootstrap container, so the documented static checks include `shellcheck -x scripts/*.sh` alongside `bash -n`.
- 2026-06-16 - Decision: The default local workflow does not assume a registry on `localhost:5000`; local image tags live in the host Docker daemon, and registry configs are explicit opt-ins.
- 2026-06-16 - Caveat: On the observed host path, port `5000` answered as Apple AirTunes/AirPlay rather than Docker Registry, so the optional local registry example uses port `5001`.
- 2026-06-16 - Finding: The ignored `cicd-common/` reference uses `mcr.microsoft.com/devcontainers/base:3.0.1-ubuntu22.04` and a large hand-built toolchain image.
- 2026-06-16 - Decision: Env files use only `UPSTREAM_BASE_IMAGE` and `BASE_IMAGE` for image coordinates; language/tool template placeholders were intentionally removed until that layer is designed.
- 2026-06-16 - Decision: `base-dod` is an image build product, not a Dev Container Template. The first future template boundary should be the language/tool template.
- 2026-06-16 - Decision: `REGISTRY` is treated as an image prefix, `BASE_IMAGE_NAME` is the image repository name, and `BASE_IMAGE_VERSION` is the explicit version knob for the built base image.
- 2026-06-16 - Decision: Top-level scripts use `scripts/lib/env.sh` so `DOCKER_ENV_FILE` is resolved relative to the repo root and required config values fail fast.
- 2026-06-16 - Decision: The canonical default env file is `docker.env` at the repo root; root-level `*.local.env` files are private overrides, and `docker.local.example.env` is the tracked local-registry example.
- 2026-06-16 - Finding: The tested DOD base image reports Docker CLI `29.5.3`, Compose `2.40.3`, and Buildx `0.34.1`; `docker.env` records those observed runtime versions as `29.5.3-1`, `2.40.3`, and `0.34.1-1`.
- 2026-06-16 - Decision: Pin compose-switch with `DOD_COMPOSE_SWITCH_VERSION=1.0.5`; the feature's unpinned compose-switch path stays disabled, and `scripts/build-base-dod.sh` adds the pinned switch in a final image layer.
