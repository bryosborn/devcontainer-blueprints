# AGENTS.md

This repository is a local-first Dev Container Template playground. Future agents should read this file before making changes, then update the learned lessons log at the bottom when they discover something that would help the next session.

## Project Goal

Build a boring, minimal skeleton that proves this planned flow:

```text
local template
  -> cicd-common-style upstream base image
  -> base-dod image with Docker-outside-of-Docker only
  -> base-vscode image with a pinned VS Code Server payload
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
BASE_VSCODE_IMAGE:   devcontainers/base-vscode:0.1.0
BASE_TOOLCHAIN_IMAGE: devcontainers/base-toolchain:0.1.0
BASE_VSCODE_VERSION: 1.124.2
Default config:      docker.env
```

## Repository Map

- `README.md`: User-facing workflow and explanation.
- `.devcontainer/`: Bootstrap development container for working on this repo.
- `docker.env`: Default host Docker daemon image coordinates.
- `docker.local.example.env`: Optional local-registry env example; copy to ignored `docker.local.env`.
- `scripts/prefetch-all.sh`: Connected-machine wrapper for all artifact prefetch steps.
- `scripts/build-all.sh`: Connected-machine wrapper for the DOD, VS Code, and toolchain image builds.
- `scripts/test-all.sh`: Wrapper for the current smoke/offline test suite.
- `scripts/pull-upstream-base-image.sh`: Pulls `UPSTREAM_BASE_IMAGE`.
- `scripts/build-base-dod.sh`: Builds `BASE_IMAGE` with the DOD feature and `moby=false`.
- `scripts/package-artifacts.sh`: Saves configured `ARTIFACT_IMAGE_REFS` into `artifacts/docker-images/`, writes `artifacts/manifest.json`, then creates a tar.gz bundle of the full `artifacts/` directory.
- `scripts/load-artifacts.sh`: Disconnected-machine helper that verifies and `docker load`s bundled image tar files.
- `scripts/test-base-dod.sh`: Smoke tests the DOD base image.
- `src/base-vscode/`: Dev Container Template that extends `BASE_IMAGE` and bakes a selected VS Code Server commit into `/home/vscode/.vscode-server/bin`.
- `src/base-vscode/scripts/`: VS Code Server artifact and `base-vscode` template build/test workflow.
- `src/base-vscode/scripts/prefetch-server.sh`: Online step that resolves/downloads the configured VS Code Server archive into `artifacts/vscode-server/`.
- `src/base-vscode/scripts/install-server.sh`: Offline install helper copied into Docker build contexts.
- `src/base-vscode/scripts/build-template.sh`: Builds `BASE_VSCODE_IMAGE` from `src/base-vscode`.
- `src/base-vscode/scripts/test-template.sh`: Smoke tests `BASE_VSCODE_IMAGE` with `--network=none`.
- `src/base-vscode/scripts/test-server-install.sh`: Builds `test/Dockerfile.vscode-server` with `docker build --network=none`.
- `src/base-vscode/scripts/prefetch-extensions.sh`: Online step that resolves/downloads VS Code extension VSIX artifacts into `artifacts/vscode-extensions/`.
- `src/base-vscode/scripts/prefetch-extensions.mjs`: Marketplace resolver that checks VS Code version compatibility, target platform, dependencies, extension packs, extension kind, and hashes.
- `src/base-vscode/scripts/install-extensions.sh`: Offline install helper that installs local VSIX files in lockfile order through the preinstalled VS Code Server CLI.
- `src/base-vscode/scripts/test-extension-resolver.mjs`: Local resolver behavior tests for semver, extension kind, dependency/pack ordering, built-ins, and cycle detection.
- `src/base-vscode/scripts/test-extensions-install.sh`: Builds `src/base-vscode/test/Dockerfile.extensions` with `docker build --network=none`.
- `config/vscode-extensions.txt`: Initial VS Code extension source list adapted from `cicd-common/extensions.txt`.
- `config/vscode-extensions.env`: Defaults for extension prefetch target platform, artifact root, server metadata, and remote user.
- `scripts/lib/env.sh`: Shared env-file loading, required-variable checks, and image-ref helpers.
- `scripts/start-local-registry.sh`: Optional helper for registry experiments.
- `cicd-common/`: Ignored reference extraction from `cicd-common.zip`; do not edit or stage.
- `src/apt-artifacts/`: APT package root list and scripts for prefetching `.deb` artifacts into a local file-backed apt repo, then testing offline install with `docker build --network=none`.
- `config/toolchain.env`: Central version/hash knobs for modular toolchain artifact downloads.
- `src/tool-artifacts/`: Modular toolchain artifact workflow. Current modules cover Java/Maven, Node, CLI tools, MongoDB client tools, and Rust.
- `src/tool-artifacts/scripts/prefetch-all.sh`: Online step that downloads all current toolchain module artifacts into `artifacts/toolchain/`.
- `src/tool-artifacts/scripts/test-all.sh`: Runs each current toolchain module's offline install test.
- `src/base-toolchain/`: Composed image layer extending `BASE_VSCODE_IMAGE` with APT, toolchain, and VS Code extension artifacts installed offline.
- `src/base-toolchain/scripts/build-image.sh`: Builds `BASE_TOOLCHAIN_IMAGE` with `docker build --network=none` and named BuildKit artifact contexts.
- `src/base-toolchain/scripts/test-image.sh`: Smoke tests the composed image, including Python 3.12/3.13, Java/Maven, Node, CLI tools, VS Code Server/extensions, and DOD CLI-only behavior.
- `src/base-toolchain/scripts/compare-cicd-common.sh`: Checks composed image paths, symlinks, env vars, versions, VS Code Server layout, and Rust components against the local `cicd-common` reference intent.

## Design Rules

- Keep this first version minimal.
- Do not add GitHub Actions, GHCR publishing, custom Dev Container Features, Docker-in-Docker, Compose services, language stacks, or enterprise registry plumbing yet.
- The target base family should match the `cicd-common` reference: `mcr.microsoft.com/devcontainers/base:3.0.1-ubuntu22.04`.
- `base-dod` is the built image containing only Docker-outside-of-Docker installed through the Dev Container Feature installer.
- `base-vscode` is the first actual Dev Container Template boundary; it should reuse `BASE_IMAGE` and bake the configured VS Code Server commit.
- `BASE_VSCODE_VERSION` is the normal user-facing selector. `BASE_VSCODE_COMMIT` is optional and should be left empty unless an exact VS Code client commit override is needed.
- VS Code Server downloads happen only in `src/base-vscode/scripts/prefetch-server.sh`; the template Dockerfile and test Dockerfile should install from `artifacts/vscode-server/` and must not run `curl`.
- Install both known VS Code Server layouts: `~/.vscode-server/cli/servers/Stable-<commit>/server` and `~/.vscode-server/bin/<commit>`, with the legacy `<commit>/0` marker.
- VS Code extension downloads happen only in `src/base-vscode/scripts/prefetch-extensions.sh` / `.mjs`; Docker builds should install from local VSIX artifacts and lockfiles only.
- VS Code extension lockfiles should record exact versions, target platform, SHA256, install order, extension kind classification, host-only extensions, built-in dependencies, and warnings.
- UI-only VS Code extensions should not be installed in the container by default; record them as host-only in the lockfile.
- The final smoke test should run with `--network=none`.
- APT artifacts should be saved under `artifacts/apt/` as `.deb` files plus `Packages`, `Packages.gz`, `SHA256SUMS`, and metadata. The install path should use a local `file:` apt repo and be tested with `docker build --network=none`.
- Toolchain versions should live in `config/toolchain.env`. Hashes are optional while exploring, but filled-in hash values are strict verification pins.
- Toolchain modules should remain split by install shape under `src/tool-artifacts/`. Docker build tests should use BuildKit bind mounts for `artifacts/toolchain/` so raw downloaded archives do not become image layers.
- `base-toolchain` composes existing artifact workflows; keep source install helpers modular and bring artifacts in with named BuildKit contexts instead of copying raw caches into the build workspace.
- Dockerfiles should use the built-in BuildKit Dockerfile frontend unless there is a specific need for an external syntax image. Adding `# syntax=docker/dockerfile:...` makes disconnected builds resolve that image before any `--network=none` build step starts, so package/load that frontend image if one is ever reintroduced.
- Python 3.12/3.13 come from the APT artifact layer as `python3.12-full` and `python3.13-full`. The composed image unpacks bundled pip wheels into global dist-packages and exposes `python3.12 -m pip`, `python3.13 -m pip`, `pip3.12`, and `pip3.13`.
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
find scripts src/base-vscode/scripts src/base-toolchain/scripts src/apt-artifacts/scripts src/tool-artifacts -type f -name '*.sh' -print0 | sort -z | xargs -0 -n1 bash -n
find scripts src/base-vscode/scripts src/base-toolchain/scripts src/apt-artifacts/scripts src/tool-artifacts -type f -name '*.sh' -print0 | sort -z | xargs -0 shellcheck -x
jq empty src/base-vscode/devcontainer-template.json src/base-vscode/.devcontainer/devcontainer.json src/base-toolchain/devcontainer-template.json src/base-toolchain/.devcontainer/devcontainer.json
npm run test:vscode-extensions
find scripts src/base-vscode/scripts src/base-toolchain/scripts src/apt-artifacts/scripts src/tool-artifacts -type f -name '*.sh' -printf '%m %p\n' | sort
```

Current online preparation:

```bash
./scripts/prefetch-all.sh
./scripts/build-all.sh
./scripts/test-all.sh
./scripts/package-artifacts.sh
```

Disconnected restore/build:

```bash
sha256sum -c artifacts-base-toolchain-0.1.0.tar.gz.sha256
tar -xzf artifacts-base-toolchain-0.1.0.tar.gz
./scripts/load-artifacts.sh
./src/base-toolchain/scripts/build-image.sh
./src/base-toolchain/scripts/test-image.sh
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

- 2026-06-16 - Finding: `shellcheck` is available in the current bootstrap container, so the documented static checks include recursive `shellcheck -x` alongside `bash -n`.
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
- 2026-06-16 - Decision: `src/base-vscode` is the first template boundary. It extends the built DOD base image and bakes a configured VS Code Server commit.
- 2026-06-16 - Decision: VS Code Server artifacts are prefetched into `artifacts/vscode-server/`; Docker builds install them offline through `src/base-vscode/scripts/install-server.sh` instead of downloading from the Dockerfile.
- 2026-06-16 - Decision: Keep VS Code Server/template workflow scripts under `src/base-vscode/scripts/` so top-level `scripts/` remains focused on base image and registry helpers.
- 2026-06-16 - Decision: `BASE_VSCODE_VERSION` is the preferred selector for `base-vscode`; scripts resolve the prefetched commit from metadata, while `BASE_VSCODE_COMMIT` remains an optional exact override.
- 2026-06-16 - Decision: APT artifact support lives under `src/apt-artifacts/`; it prefetches package roots into a local apt repo and tests install through `docker build --network=none`.
- 2026-06-16 - Decision: VS Code extension artifact support lives under `src/base-vscode/scripts/`; it resolves Marketplace VSIX files against the prefetched VS Code Server product version and writes `artifacts/vscode-extensions/vscode-extensions.lock.json`.
- 2026-06-16 - Finding: Some VS Code extension dependencies use `vscode.*` built-in extension IDs such as `vscode.docker` and `vscode.yaml`; these are recorded as built-in dependencies, not downloaded VSIX files.
- 2026-06-16 - Finding: The current Python extension set contains a dependency cycle between `ms-python.python` and `ms-python.debugpy`; the resolver records a warning and uses deterministic resolution order for install.
- 2026-06-16 - Decision: Remote development extension pack members classify as host-only and are locked but not installed into the container by default.
- 2026-06-16 - Decision: Toolchain artifact support lives under `src/tool-artifacts/`, with easy version/hash knobs in `config/toolchain.env` and module install tests that bind-mount artifacts during Docker builds.
- 2026-06-16 - Decision: `src/base-toolchain` composes the existing offline artifact workflows into `BASE_TOOLCHAIN_IMAGE` using named BuildKit contexts and `docker build --network=none`.
- 2026-06-16 - Finding: Python 3.12/3.13 are available from the APT artifact layer with `venv`; the composed image now adds global pip wrappers from the bundled ensurepip wheels.
- 2026-06-16 - Decision: The composed image sets `JAVA_HOME=/opt/java`, fixes kubectl and yq symlinks to match the `cicd-common` install paths, and adds global pip wrappers for Python 3.12/3.13.
- 2026-06-16 - Decision: MongoDB client parity is scoped to `mongosh` and MongoDB Database Tools only; MongoDB server packages are intentionally out of scope.
- 2026-06-16 - Decision: Rust is prefetched by installing the pinned `nightly-2026-04-11` toolchain and required components into artifact-owned Rust/Cargo homes, then copied offline into `/usr/local/rustup` and `/usr/local/cargo`.
- 2026-06-16 - Decision: `scripts/package-artifacts.sh` writes the compressed `artifacts/` bundle outside the artifact root to avoid self-inclusion.
- 2026-06-17 - Finding: `# syntax=docker/dockerfile:1.7` makes BuildKit resolve `docker/dockerfile:1.7` before the build starts, so disconnected builds can fail before any `--network=none` step runs.
- 2026-06-17 - Decision: The current Dockerfiles use the built-in BuildKit frontend, which supports the named bind mounts used here and avoids the external frontend image lookup.
- 2026-06-17 - Decision: `scripts/package-artifacts.sh` now saves all configured `ARTIFACT_IMAGE_REFS`, writes portable SHA256 files and `artifacts/manifest.json`, and `scripts/load-artifacts.sh` verifies/loads those images on the disconnected machine.
